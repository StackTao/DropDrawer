use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use chrono::{DateTime, Utc};
use protocol::{P2pPathKind, P2pTransferProgress};
use serde::{Deserialize, Serialize};
use tokio::runtime::Runtime;
use uuid::Uuid;

use crate::{P2pConfig, P2pNode};

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static NODE: OnceLock<Mutex<Option<Arc<P2pNode>>>> = OnceLock::new();

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("dropdrawer-p2p")
            .build()
            .expect("failed creating tokio runtime for P2P FFI")
    })
}

fn node_slot() -> &'static Mutex<Option<Arc<P2pNode>>> {
    NODE.get_or_init(|| Mutex::new(None))
}

#[derive(Serialize)]
struct FfiResult<T: Serialize> {
    ok: bool,
    data: Option<T>,
    error: Option<String>,
}

fn to_c_json<T: Serialize>(res: Result<T, String>) -> *mut c_char {
    let payload = match res {
        Ok(data) => FfiResult {
            ok: true,
            data: Some(data),
            error: None,
        },
        Err(err) => FfiResult {
            ok: false,
            data: None,
            error: Some(err),
        },
    };
    let s = serde_json::to_string(&payload).unwrap_or_else(|_| {
        r#"{"ok":false,"data":null,"error":"serialization error"}"#.to_string()
    });
    CString::new(s).unwrap().into_raw()
}

unsafe fn parse_c_str(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("null pointer".to_string());
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map(str::to_string)
        .map_err(|e| format!("invalid utf-8: {e}"))
}

fn current_node() -> Result<Arc<P2pNode>, String> {
    node_slot()
        .lock()
        .map_err(|_| "mutex poisoned".to_string())?
        .clone()
        .ok_or_else(|| "P2P node is not started".to_string())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dropdrawer_p2p_start(config_json: *const c_char) -> *mut c_char {
    let res = (|| -> Result<_, String> {
        let raw = unsafe { parse_c_str(config_json)? };
        let cfg: P2pConfig = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
        let node = runtime()
            .block_on(P2pNode::start(cfg, true))
            .map_err(|e| e.to_string())?;
        let info = node.node_info();
        *node_slot().lock().map_err(|_| "mutex poisoned".to_string())? = Some(node);
        Ok(info)
    })();
    to_c_json(res)
}

#[unsafe(no_mangle)]
pub extern "C" fn dropdrawer_p2p_node_info() -> *mut c_char {
    let res = current_node().map(|n| n.node_info());
    to_c_json(res)
}

#[derive(Deserialize)]
struct RegisterFileReq {
    item_id: String,
    path: String,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dropdrawer_p2p_register_file(req_json: *const c_char) -> *mut c_char {
    let res = (|| -> Result<_, String> {
        let node = current_node()?;
        let raw = unsafe { parse_c_str(req_json)? };
        let req: RegisterFileReq = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
        runtime()
            .block_on(node.register_file(req.item_id, req.path))
            .map_err(|e| e.to_string())
    })();
    to_c_json(res)
}

#[derive(Deserialize)]
struct AuthorizeTokenReq {
    item_id: String,
    token: String,
    expires_at: DateTime<Utc>,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dropdrawer_p2p_authorize_token(req_json: *const c_char) -> *mut c_char {
    let res = (|| -> Result<_, String> {
        let node = current_node()?;
        let raw = unsafe { parse_c_str(req_json)? };
        let req: AuthorizeTokenReq = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
        node.authorize_token(req.item_id, req.token, req.expires_at);
        Ok(true)
    })();
    to_c_json(res)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dropdrawer_p2p_unregister_file(item_id: *const c_char) -> *mut c_char {
    let res = (|| -> Result<_, String> {
        let node = current_node()?;
        let id = unsafe { parse_c_str(item_id)? };
        node.unregister_file(&id);
        Ok(true)
    })();
    to_c_json(res)
}

#[derive(Deserialize)]
struct DownloadFileReq {
    item_id: String,
    remote_node_id: String,
    #[serde(default)]
    remote_relay_url: Option<String>,
    #[serde(default)]
    remote_direct_addrs: Vec<String>,
    transfer_token: String,
    dest_path: String,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dropdrawer_p2p_download_file(req_json: *const c_char) -> *mut c_char {
    let res = (|| -> Result<_, String> {
        let node = current_node()?;
        let raw = unsafe { parse_c_str(req_json)? };
        let req: DownloadFileReq = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
        let handle_id = Uuid::new_v4().to_string();
        let item_id = req.item_id.clone();

        runtime().spawn(async move {
            if let Err(err) = node
                .download_file(
                    req.item_id.clone(),
                    req.remote_node_id,
                    req.remote_relay_url,
                    req.remote_direct_addrs,
                    req.transfer_token,
                    PathBuf::from(req.dest_path),
                )
                .await
            {
                node.push_event(P2pTransferProgress {
                    transfer_id: handle_id,
                    item_id,
                    bytes_transferred: 0,
                    total_bytes: 0,
                    speed_bps: 0,
                    path_kind: P2pPathKind::Unknown,
                    finished: true,
                    saved_path: None,
                    error: Some(err.to_string()),
                });
            }
        });

        Ok(true)
    })();
    to_c_json(res)
}

#[unsafe(no_mangle)]
pub extern "C" fn dropdrawer_p2p_poll_events() -> *mut c_char {
    let res = current_node().map(|n| n.drain_events());
    to_c_json(res)
}

#[unsafe(no_mangle)]
pub extern "C" fn dropdrawer_p2p_shutdown() -> *mut c_char {
    let res = (|| -> Result<_, String> {
        let maybe = node_slot()
            .lock()
            .map_err(|_| "mutex poisoned".to_string())?
            .take();
        if let Some(node) = maybe {
            runtime().block_on(node.shutdown());
        }
        Ok(true)
    })();
    to_c_json(res)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dropdrawer_p2p_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        let _ = unsafe { CString::from_raw(ptr) };
    }
}
