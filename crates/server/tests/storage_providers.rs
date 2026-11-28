//! Quark, Baidu Netdisk and WebDAV against local mock servers that follow the
//! real services' behaviour where it matters (WebDAV `409` for a missing parent
//! collection, Baidu single-use refresh tokens, Quark instant upload and OSS
//! multipart upload).

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use axum::{
    body::Body,
    extract::{Request, State},
    response::Response,
    Router,
};
use bytes::Bytes;
use dropdrawer_server::storage::{
    baidu::{BaiduNetdiskConfig, BaiduNetdiskProvider, BaiduTokenSink, BaiduTokens},
    quark::QuarkProvider,
    webdav::WebDavProvider,
    ByteStream, DownloadResolution, StorageProvider,
};
use futures_util::TryStreamExt;
use serde_json::{json, Value};

#[derive(Clone, Debug)]
struct Recorded {
    method: String,
    host: String,
    path: String,
    query: HashMap<String, String>,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

impl Recorded {
    fn form(&self) -> HashMap<String, String> {
        url::form_urlencoded::parse(&self.body).into_owned().collect()
    }

    fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or(Value::Null)
    }
}

type Reply = (u16, Vec<(&'static str, String)>, Vec<u8>);
type Responder = Arc<dyn Fn(&Recorded) -> Reply + Send + Sync>;

#[derive(Clone)]
struct Mock {
    log: Arc<Mutex<Vec<Recorded>>>,
    responder: Responder,
}

impl Mock {
    fn requests(&self) -> Vec<Recorded> {
        self.log.lock().unwrap().clone()
    }

    fn paths(&self) -> Vec<String> {
        self.requests().into_iter().map(|r| format!("{} {}", r.method, r.path)).collect()
    }
}

fn json_reply(value: Value) -> Reply {
    (200, vec![("content-type", "application/json".to_string())], value.to_string().into_bytes())
}

async fn handle(State(mock): State<Mock>, req: Request) -> Response {
    let (parts, body) = req.into_parts();
    let body = axum::body::to_bytes(body, usize::MAX).await.unwrap_or_default();
    let recorded = Recorded {
        method: parts.method.to_string(),
        host: parts
            .headers
            .get("host")
            .and_then(|h| h.to_str().ok())
            .unwrap_or_default()
            .to_string(),
        path: parts.uri.path().to_string(),
        query: url::form_urlencoded::parse(parts.uri.query().unwrap_or("").as_bytes())
            .into_owned()
            .collect(),
        headers: parts
            .headers
            .iter()
            .map(|(k, v)| (k.as_str().to_string(), v.to_str().unwrap_or_default().to_string()))
            .collect(),
        body: body.to_vec(),
    };
    let (status, headers, body) = (mock.responder)(&recorded);
    mock.log.lock().unwrap().push(recorded);
    let mut response = Response::builder().status(status);
    for (name, value) in headers {
        response = response.header(name, value);
    }
    response.body(Body::from(body)).unwrap()
}

async fn spawn_mock(responder: impl Fn(&Recorded) -> Reply + Send + Sync + 'static) -> (String, Mock, std::net::SocketAddr) {
    let mock = Mock {
        log: Arc::default(),
        responder: Arc::new(responder),
    };
    let router = Router::new().fallback(handle).with_state(mock.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    (format!("http://{addr}"), mock, addr)
}

// The mock still advertises an HTTP OSS URL, as Quark can, but its upload
// endpoint accepts only TLS. The certificate is trusted only by this test.
struct TlsMockListener {
    listener: tokio::net::TcpListener,
    acceptor: tokio_rustls::TlsAcceptor,
}

impl axum::serve::Listener for TlsMockListener {
    type Io = tokio_rustls::server::TlsStream<tokio::net::TcpStream>;
    type Addr = std::net::SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        loop {
            let (stream, addr) = self.listener.accept().await.unwrap();
            if let Ok(stream) = self.acceptor.accept(stream).await {
                return (stream, addr);
            }
        }
    }

    fn local_addr(&self) -> std::io::Result<Self::Addr> {
        self.listener.local_addr()
    }
}

async fn spawn_tls_mock(
    responder: impl Fn(&Recorded) -> Reply + Send + Sync + 'static,
) -> (String, Mock, std::net::SocketAddr, reqwest::Certificate) {
    use tokio_rustls::rustls::{ServerConfig, crypto::ring, pki_types::PrivatePkcs8KeyDer};

    let certificate = rcgen::generate_simple_self_signed(vec![
        "quark.test".into(),
        "drops.oss.test".into(),
    ]).unwrap();
    let cert = certificate.cert.der().clone();
    let private_key = PrivatePkcs8KeyDer::from(certificate.key_pair.serialize_der());
    let server = ServerConfig::builder_with_provider(Arc::new(ring::default_provider()))
        .with_safe_default_protocol_versions().unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![cert.clone()], private_key.into()).unwrap();
    let trust = reqwest::Certificate::from_der(cert.as_ref()).unwrap();
    let mock = Mock {
        log: Arc::default(),
        responder: Arc::new(responder),
    };
    let router = Router::new().fallback(handle).with_state(mock.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let listener = TlsMockListener {
        listener,
        acceptor: tokio_rustls::TlsAcceptor::from(Arc::new(server)),
    };
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    (format!("https://quark.test:{}", addr.port()), mock, addr, trust)
}

fn body_stream(chunks: &[&'static [u8]]) -> ByteStream {
    let chunks: Vec<Result<Bytes, anyhow::Error>> =
        chunks.iter().map(|c| Ok(Bytes::from_static(c))).collect();
    Box::pin(futures_util::stream::iter(chunks))
}

async fn read_download(resolution: DownloadResolution) -> Vec<u8> {
    match resolution {
        DownloadResolution::Stream { stream, .. } => {
            let parts: Vec<Bytes> = stream.try_collect().await.unwrap();
            parts.concat()
        }
        DownloadResolution::DirectUrl(url) => panic!("unexpected direct URL {url}"),
    }
}

fn unique(prefix: &str) -> String {
    format!("{prefix}-{}", uuid::Uuid::new_v4())
}

// ---------------------------------------------------------------------------
// WebDAV
// ---------------------------------------------------------------------------

#[tokio::test]
async fn webdav_creates_parent_collections_and_round_trips_files() {
    let files: Arc<Mutex<HashMap<String, Vec<u8>>>> = Arc::default();
    let collections: Arc<Mutex<HashSet<String>>> =
        Arc::new(Mutex::new(HashSet::from(["/dav/".to_string()])));
    let (base, mock, _) = {
        let files = files.clone();
        let collections = collections.clone();
        spawn_mock(move |req| {
            // "user:secret" in basic auth.
            if req.headers.get("authorization").map(String::as_str) != Some("Basic dXNlcjpzZWNyZXQ=") {
                return (401, vec![], vec![]);
            }
            let parent = match req.path.trim_end_matches('/').rsplit_once('/') {
                Some((parent, _)) => format!("{parent}/"),
                None => "/".to_string(),
            };
            match req.method.as_str() {
                "PROPFIND" => (207, vec![], b"<multistatus/>".to_vec()),
                "MKCOL" => {
                    if !collections.lock().unwrap().contains(&parent) {
                        return (409, vec![], vec![]);
                    }
                    if !collections.lock().unwrap().insert(req.path.clone()) {
                        return (405, vec![], vec![]);
                    }
                    (201, vec![], vec![])
                }
                "PUT" => {
                    if !collections.lock().unwrap().contains(&parent) {
                        return (409, vec![], vec![]);
                    }
                    files.lock().unwrap().insert(req.path.clone(), req.body.clone());
                    (201, vec![], vec![])
                }
                "GET" | "HEAD" => match files.lock().unwrap().get(&req.path) {
                    Some(bytes) => (200, vec![("content-type", "text/plain".into())], bytes.clone()),
                    None => (404, vec![], vec![]),
                },
                "DELETE" => match files.lock().unwrap().remove(&req.path) {
                    Some(_) => (204, vec![], vec![]),
                    None => (404, vec![], vec![]),
                },
                _ => (405, vec![], vec![]),
            }
        })
        .await
    };
    let provider = WebDavProvider::new(
        reqwest::Client::new(),
        format!("{base}/dav/"),
        "user".into(),
        "secret".into(),
    );
    assert!(provider.health_check().await.unwrap().contains("/dav"));
    let propfind = mock.requests().into_iter().find(|r| r.method == "PROPFIND").unwrap();
    assert_eq!(propfind.headers["depth"], "0");

    // The owner's folder does not exist yet: it is created before the PUT.
    let put = provider
        .put_stream("user-1/item 1_report.txt", Some(11), body_stream(&[b"hello ", b"world"]))
        .await
        .unwrap();
    assert_eq!(put.bytes_written, 11);
    assert_eq!(put.stored_key, "user-1/item 1_report.txt");
    assert_eq!(
        files.lock().unwrap().get("/dav/user-1/item%201_report.txt").map(Vec::as_slice),
        Some(&b"hello world"[..])
    );
    // A second file in the same folder: MKCOL answers 405 (exists), which is fine.
    provider
        .put_stream("user-1/second.txt", None, body_stream(&[b"2"]))
        .await
        .unwrap();
    let mkcols = mock.paths().into_iter().filter(|p| p.starts_with("MKCOL")).count();
    assert_eq!(mkcols, 2);

    assert!(provider.object_exists("user-1/item 1_report.txt").await.unwrap());
    assert!(!provider.object_exists("user-1/missing.txt").await.unwrap());
    let downloaded = read_download(provider.resolve_download("user-1/item 1_report.txt").await.unwrap()).await;
    assert_eq!(downloaded, b"hello world");

    provider.delete("user-1/item 1_report.txt").await.unwrap();
    // Already gone counts as deleted.
    provider.delete("user-1/item 1_report.txt").await.unwrap();
    assert!(!provider.object_exists("user-1/item 1_report.txt").await.unwrap());

    let wrong = WebDavProvider::new(reqwest::Client::new(), format!("{base}/dav"), "user".into(), "nope".into());
    assert!(wrong.health_check().await.is_err());
    assert!(wrong.put_stream("user-1/x.txt", None, body_stream(&[b"x"])).await.is_err());
}

// ---------------------------------------------------------------------------
// Quark
// ---------------------------------------------------------------------------

const QUARK_COOKIE: &str = "__pus=test-session; __puus=test-refresh";

fn quark_envelope(data: Value) -> Reply {
    json_reply(json!({"status": 200, "code": 0, "message": "ok", "data": data}))
}

#[tokio::test]
async fn quark_uses_instant_upload_when_the_cloud_has_the_file() {
    let (base, mock, _) = spawn_mock(|req| {
        if req.headers.get("cookie").map(String::as_str) != Some(QUARK_COOKIE) {
            return json_reply(json!({"code": 31001, "message": "require login [guest]"}));
        }
        match req.path.as_str() {
            "/1/clouddrive/file/sort" => quark_envelope(json!({"list": []})),
            "/1/clouddrive/file/upload/pre" => quark_envelope(json!({"task_id": "task-1", "finish": false})),
            "/1/clouddrive/file/update/hash" => quark_envelope(json!({"finish": true, "fid": "fid-instant"})),
            "/1/clouddrive/file/download" => {
                let host = req.headers["host"].clone();
                quark_envelope(json!([{"download_url": format!("http://{host}/blob/fid-instant"), "size": 5}]))
            }
            "/blob/fid-instant" => (200, vec![], b"quark".to_vec()),
            "/1/clouddrive/file/delete" => quark_envelope(json!({"task_id": "del-1"})),
            _ => (404, vec![], vec![]),
        }
    })
    .await;
    let provider = QuarkProvider::new(reqwest::Client::new(), QUARK_COOKIE.into(), "folder-9".into(), Some(base.clone()));
    assert!(provider.health_check().await.unwrap().contains("folder-9"));
    let sort = mock.requests().into_iter().find(|r| r.path.ends_with("/sort")).unwrap();
    assert_eq!(sort.query["pdir_fid"], "folder-9");
    assert_eq!(sort.headers["referer"], "https://pan.quark.cn/");

    let put = provider
        .put_stream("user-1/item_photo.jpg", Some(5), body_stream(&[b"qua", b"rk"]))
        .await
        .unwrap();
    assert_eq!(put.stored_key, "fid-instant");
    assert_eq!(put.bytes_written, 5);
    let requests = mock.requests();
    let pre = requests.iter().find(|r| r.path.ends_with("/upload/pre")).unwrap().json();
    assert_eq!(pre["pdir_fid"], "folder-9");
    assert_eq!(pre["file_name"], "item_photo.jpg");
    assert_eq!(pre["size"], 5);
    let hash = requests.iter().find(|r| r.path.ends_with("/update/hash")).unwrap().json();
    assert_eq!(hash["task_id"], "task-1");
    assert_eq!(hash["md5"], "57b7d993ffbd75aca3fe2060cf204f93"); // md5("quark")
    assert_eq!(hash["sha1"], "b58c9904ba6f4a89d1b64ca1214dfbdfb0cde76d"); // sha1("quark")
    assert!(!requests.iter().any(|r| r.path.ends_with("/upload/auth")), "no OSS upload needed");

    let downloaded = read_download(provider.resolve_download("fid-instant").await.unwrap()).await;
    assert_eq!(downloaded, b"quark");
    let blob = mock.requests().into_iter().find(|r| r.path == "/blob/fid-instant").unwrap();
    assert_eq!(blob.headers["cookie"], QUARK_COOKIE, "the download is proxied with the cookie");

    provider.delete("fid-instant").await.unwrap();
    let delete = mock.requests().into_iter().find(|r| r.path.ends_with("/file/delete")).unwrap().json();
    assert_eq!(delete["filelist"], json!(["fid-instant"]));

    let expired = QuarkProvider::new(reqwest::Client::new(), "__pus=stale".into(), "0".into(), Some(base));
    let err = expired.health_check().await.unwrap_err().to_string();
    assert!(err.contains("31001"), "{err}");
    assert!(expired.delete("fid-instant").await.is_err());
}

#[tokio::test]
async fn quark_uploads_new_files_in_oss_parts_and_commits_them() {
    let parts: Arc<Mutex<Vec<(u32, Vec<u8>)>>> = Arc::default();
    let (base, mock, addr, trust) = {
        let parts = parts.clone();
        spawn_tls_mock(move |req| {
            let oss = req.host.starts_with("drops.oss.test");
            match (oss, req.method.as_str(), req.path.as_str()) {
                (false, _, "/1/clouddrive/file/upload/pre") => json_reply(json!({
                    "code": 0,
                    "data": {
                        "task_id": "task-2",
                        "finish": false,
                        "upload_id": "upload-7",
                        "obj_key": "objects/new.bin",
                        "upload_url": format!("http://oss.test:{}", req.host.rsplit(':').next().unwrap_or("80")),
                        "bucket": "drops",
                        "auth_info": "auth-info",
                        "callback": {"callbackUrl": "https://example.test/cb", "callbackBody": "x"},
                    },
                    "metadata": {"part_size": 4},
                })),
                (false, _, "/1/clouddrive/file/update/hash") => quark_envelope(json!({"finish": false})),
                (false, _, "/1/clouddrive/file/upload/auth") => {
                    let meta = req.json()["auth_meta"].as_str().unwrap_or_default().to_string();
                    quark_envelope(json!({"auth_key": format!("OSS signed:{}", meta.lines().next().unwrap_or(""))}))
                }
                (true, "PUT", "/objects/new.bin") => {
                    assert_eq!(req.query["uploadId"], "upload-7");
                    assert!(req.headers["authorization"].starts_with("OSS signed:PUT"));
                    let number: u32 = req.query["partNumber"].parse().unwrap();
                    parts.lock().unwrap().push((number, req.body.clone()));
                    (200, vec![("etag", format!("\"etag-{number}\""))], vec![])
                }
                (true, "POST", "/objects/new.bin") => {
                    assert!(req.headers["authorization"].starts_with("OSS signed:POST"));
                    assert!(req.headers.contains_key("x-oss-callback"));
                    (200, vec![], b"{\"Status\":\"OK\"}".to_vec())
                }
                (false, _, "/1/clouddrive/file/upload/finish") => quark_envelope(json!({"fid": "fid-new"})),
                _ => (404, vec![], vec![]),
            }
        })
        .await
    };
    // The OSS host is "<bucket>.<upload host>", which must resolve to the mock.
    let http = reqwest::Client::builder()
        .resolve("quark.test", addr)
        .resolve("drops.oss.test", addr)
        .add_root_certificate(trust)
        .no_proxy()
        .build()
        .unwrap();
    let provider = QuarkProvider::new(http, QUARK_COOKIE.into(), "0".into(), Some(base));
    let put = provider
        .put_stream("user-1/new.bin", None, body_stream(&[b"0123456789"]))
        .await
        .unwrap();
    assert_eq!(put.stored_key, "fid-new");
    assert_eq!(put.bytes_written, 10);

    let mut uploaded = parts.lock().unwrap().clone();
    uploaded.sort_by_key(|(n, _)| *n);
    assert_eq!(
        uploaded,
        vec![(1, b"0123".to_vec()), (2, b"4567".to_vec()), (3, b"89".to_vec())]
    );
    let commit = mock
        .requests()
        .into_iter()
        .find(|r| r.method == "POST" && r.path == "/objects/new.bin")
        .unwrap();
    let xml = String::from_utf8(commit.body).unwrap();
    for n in 1..=3 {
        assert!(xml.contains(&format!("<Part><PartNumber>{n}</PartNumber><ETag>\"etag-{n}\"</ETag></Part>")), "{xml}");
    }
    let finish = mock.requests().into_iter().find(|r| r.path.ends_with("/upload/finish")).unwrap().json();
    assert_eq!(finish["task_id"], "task-2");
    assert_eq!(finish["obj_key"], "objects/new.bin");
}

// ---------------------------------------------------------------------------
// Baidu Netdisk
// ---------------------------------------------------------------------------

/// Mock Baidu OAuth that, like the real one, accepts each refresh token once.
async fn spawn_baidu_mock() -> (String, Mock, Arc<Mutex<Vec<String>>>) {
    let spent: Arc<Mutex<Vec<String>>> = Arc::default();
    let files: Arc<Mutex<HashMap<String, Vec<u8>>>> = Arc::default();
    let spent_in_mock = spent.clone();
    let (base, mock, _) = spawn_mock(move |req| {
        let access_ok = |req: &Recorded| {
            req.query.get("access_token").is_some_and(|t| t.starts_with("access-"))
        };
        match req.path.as_str() {
            "/oauth/2.0/token" => {
                let form = req.form();
                let token = form.get("refresh_token").cloned().unwrap_or_default();
                let mut spent = spent_in_mock.lock().unwrap();
                if !token.starts_with("refresh-") || spent.contains(&token) {
                    return (400, vec![], br#"{"error":"expired_token"}"#.to_vec());
                }
                spent.push(token.clone());
                let n = spent.len();
                json_reply(json!({
                    "access_token": format!("access-{n}"),
                    "refresh_token": format!("refresh-rotated-{n}"),
                    "expires_in": 2592000,
                }))
            }
            _ if !access_ok(req) => json_reply(json!({"errno": -6})),
            "/api/quota" => json_reply(json!({"errno": 0, "total": 2_000_000_000_000u64, "used": 1_500_000_000u64})),
            "/rest/2.0/xpan/file" => match req.query["method"].as_str() {
                "precreate" => {
                    let form = req.form();
                    assert_eq!(form["isdir"], "0");
                    assert_eq!(form["autoinit"], "1");
                    json_reply(json!({"errno": 0, "uploadid": "up-1", "return_type": 1}))
                }
                "create" => {
                    let form = req.form();
                    assert_eq!(form["uploadid"], "up-1");
                    files.lock().unwrap().insert(form["path"].clone(), b"baidu bytes".to_vec());
                    json_reply(json!({"errno": 0, "fs_id": 4242, "path": form["path"]}))
                }
                "filemanager" => {
                    assert_eq!(req.query["opera"], "delete");
                    json_reply(json!({"errno": 0}))
                }
                _ => (404, vec![], vec![]),
            },
            "/rest/2.0/pcs/superfile2" => {
                assert_eq!(req.query["uploadid"], "up-1");
                assert!(req.headers["content-type"].starts_with("multipart/form-data"));
                json_reply(json!({"md5": "x"}))
            }
            "/rest/2.0/xpan/multimedia" => {
                let host = req.headers["host"].clone();
                json_reply(json!({"errno": 0, "list": [{"dlink": format!("http://{host}/file/4242?sign=1"), "size": 11}]}))
            }
            "/file/4242" => {
                assert_eq!(req.headers["user-agent"], "pan.baidu.com");
                (200, vec![], files.lock().unwrap().values().next().cloned().unwrap_or_default())
            }
            _ => (404, vec![], vec![]),
        }
    })
    .await;
    (base, mock, spent)
}

fn baidu_config(base: &str, refresh: &str, access: &str, expires_at: Option<i64>) -> BaiduNetdiskConfig {
    BaiduNetdiskConfig {
        client_id: "app-key".into(),
        client_secret: "app-secret".into(),
        refresh_token: refresh.into(),
        access_token: access.into(),
        access_token_expires_at: expires_at,
        root_path: "/apps/dropdrawer".into(),
        api_base_url: Some(base.into()),
    }
}

#[tokio::test]
async fn baidu_saves_each_single_use_refresh_token() {
    let (base, mock, spent) = spawn_baidu_mock().await;
    let backend = unique("baidu");
    let saved: Arc<Mutex<Vec<BaiduTokens>>> = Arc::default();
    let sink: BaiduTokenSink = {
        let saved = saved.clone();
        Arc::new(move |_, tokens: &BaiduTokens| {
            saved.lock().unwrap().push(tokens.clone());
            Ok(true)
        })
    };
    let provider = |cfg: BaiduNetdiskConfig| {
        BaiduNetdiskProvider::new(reqwest::Client::new(), cfg).with_token_store(&backend, sink.clone())
    };

    // Providers are built per request from the stored config.
    let first = provider(baidu_config(&base, "refresh-original", "", None));
    assert!(first.health_check().await.unwrap().contains("GB"));
    assert_eq!(spent.lock().unwrap().as_slice(), ["refresh-original"]);
    let rotated = saved.lock().unwrap().last().cloned().unwrap();
    assert_eq!(rotated.access_token, "access-1");
    assert_eq!(rotated.refresh_token, "refresh-rotated-1");
    assert!(rotated.expires_at > chrono::Utc::now().timestamp() + 86_400);

    // A request that loaded the config before the rotation was saved still works:
    // the shared session answers instead of spending the old token again.
    let stale = provider(baidu_config(&base, "refresh-original", "", None));
    stale.health_check().await.unwrap();
    // And so does one built from the saved config.
    let fresh = provider(baidu_config(&base, &rotated.refresh_token, &rotated.access_token, Some(rotated.expires_at)));
    fresh.health_check().await.unwrap();
    assert_eq!(spent.lock().unwrap().len(), 1, "no second refresh while the access token is valid");

    // Upload, download and delete with the cached access token.
    let put = fresh
        .put_stream("user-1/item_notes.txt", Some(11), body_stream(&[b"baidu ", b"bytes"]))
        .await
        .unwrap();
    assert_eq!(put.stored_key, "4242|/apps/dropdrawer/item_notes.txt");
    let precreate = mock
        .requests()
        .into_iter()
        .find(|r| r.query.get("method").map(String::as_str) == Some("precreate"))
        .unwrap()
        .form();
    assert_eq!(precreate["path"], "/apps/dropdrawer/item_notes.txt");
    assert_eq!(precreate["size"], "11");
    // md5("baidu bytes") as the only 4 MiB block.
    let blocks: Vec<String> = serde_json::from_str(&precreate["block_list"]).unwrap();
    assert_eq!(blocks, ["43a355aa09c0cb111f07d208a2b99fe5"]);
    let downloaded = read_download(fresh.resolve_download(&put.stored_key).await.unwrap()).await;
    assert_eq!(downloaded, b"baidu bytes");
    fresh.delete(&put.stored_key).await.unwrap();
    let delete = mock
        .requests()
        .into_iter()
        .find(|r| r.query.get("opera").map(String::as_str) == Some("delete"))
        .unwrap()
        .form();
    assert_eq!(delete["filelist"], r#"["/apps/dropdrawer/item_notes.txt"]"#);

    // A config snapshot with a stale expiry uses the session's valid token.
    let expired = provider(baidu_config(&base, &rotated.refresh_token, &rotated.access_token, Some(0)));
    expired.health_check().await.unwrap();
    assert_eq!(spent.lock().unwrap().len(), 1);

    // New credentials pasted by the user start a new session.
    let replaced = provider(baidu_config(&base, "refresh-pasted", "", None));
    replaced.health_check().await.unwrap();
    assert_eq!(spent.lock().unwrap().as_slice(), ["refresh-original", "refresh-pasted"]);
    assert_eq!(saved.lock().unwrap().last().unwrap().refresh_token, "refresh-rotated-2");
}

#[tokio::test]
async fn baidu_rotation_is_written_back_to_the_encrypted_config() {
    use dropdrawer_server::{db::Database, state::AppState};
    use protocol::StorageBackendConfig;

    let (base, _mock, spent) = spawn_baidu_mock().await;
    let tmp = tempfile::TempDir::new().unwrap();
    let db = Database::open(tmp.path().join("baidu.db")).unwrap();
    db.create_user("u1", "alice", "hash").unwrap();
    let backend_id = unique("backend");
    db.create_storage_backend(
        &backend_id,
        "u1",
        "Baidu",
        &StorageBackendConfig::BaiduNetdisk {
            client_id: "app-key".into(),
            client_secret: "app-secret".into(),
            refresh_token: "refresh-first".into(),
            access_token: String::new(),
            access_token_expires_at: None,
            root_path: "/apps/dropdrawer".into(),
            api_base_url: Some(base),
        },
        true,
    )
    .unwrap();
    let state = AppState::new(db, "test-jwt-secret".into(), tmp.path().join("blobs"));
    let record = state.db.get_storage_backend(&backend_id, "u1").unwrap().unwrap();
    let provider = state.build_storage_provider(&record).unwrap();
    provider.health_check().await.unwrap();
    assert_eq!(spent.lock().unwrap().as_slice(), ["refresh-first"]);

    let record = state.db.get_storage_backend(&backend_id, "u1").unwrap().unwrap();
    assert_eq!(record.name, "Baidu");
    let StorageBackendConfig::BaiduNetdisk {
        refresh_token,
        access_token,
        access_token_expires_at,
        client_secret,
        ..
    } = record.config.clone()
    else {
        panic!("not a Baidu config");
    };
    assert_eq!(refresh_token, "refresh-rotated-1");
    assert_eq!(access_token, "access-1");
    assert!(access_token_expires_at.is_some());
    assert_eq!(client_secret, "app-secret", "other fields are kept");

    // A provider built from the saved config needs no further refresh.
    let provider = state.build_storage_provider(&record).unwrap();
    provider.health_check().await.unwrap();
    assert_eq!(spent.lock().unwrap().len(), 1);

    // A stale request built before a credentials edit cannot overwrite it.
    let mut stale_record = record.clone();
    if let StorageBackendConfig::BaiduNetdisk {
        refresh_token, access_token, access_token_expires_at, ..
    } = &mut stale_record.config {
        *refresh_token = "refresh-before-edit".into();
        access_token.clear();
        *access_token_expires_at = None;
    }
    let patch = serde_json::Map::from_iter([
        ("refresh_token".into(), json!("refresh-before-edit")),
        ("access_token".into(), json!("")),
        ("access_token_expires_at".into(), Value::Null),
    ]);
    state.db.update_storage_backend(&backend_id, "u1", "Baidu", &patch).unwrap();
    let stale_provider = state.build_storage_provider(&stale_record).unwrap();
    let patch = serde_json::Map::from_iter([("refresh_token".into(), json!("refresh-manual"))]);
    state.db.update_storage_backend(&backend_id, "u1", "Baidu", &patch).unwrap();
    let error = stale_provider.health_check().await.unwrap_err();
    assert!(error.to_string().contains("credentials changed"), "{error:#}");
    let saved = state.db.get_storage_backend(&backend_id, "u1").unwrap().unwrap();
    assert!(matches!(saved.config, StorageBackendConfig::BaiduNetdisk { refresh_token, .. }
        if refresh_token == "refresh-manual"));
}

#[tokio::test]
async fn baidu_restart_uses_the_saved_access_token() {
    // No shared session (a restarted server): a saved, unexpired pair is used as is.
    let (base, _mock, spent) = spawn_baidu_mock().await;
    let future = chrono::Utc::now().timestamp() + 86_400;
    let rotations = Arc::new(Mutex::new(0));
    let sink: BaiduTokenSink = {
        let rotations = rotations.clone();
        Arc::new(move |_, _| {
            *rotations.lock().unwrap() += 1;
            Ok(true)
        })
    };
    let provider = BaiduNetdiskProvider::new(
        reqwest::Client::new(),
        baidu_config(&base, "refresh-saved", "access-saved", Some(future)),
    )
    .with_token_store(&unique("restarted"), sink);
    provider.health_check().await.unwrap();
    assert!(spent.lock().unwrap().is_empty());
    assert_eq!(*rotations.lock().unwrap(), 0);
}
