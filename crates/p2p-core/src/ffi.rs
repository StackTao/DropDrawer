use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::{Arc, Mutex, OnceLock};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::runtime::Runtime;

use crate::{DownloadFileReq, P2pConfig, P2pNode};

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
        // Restarting must not leave the previous endpoint running and bound.
        let previous = node_slot()
            .lock()
            .map_err(|_| "mutex poisoned".to_string())?
            .take();
        if let Some(previous) = previous {
            runtime().block_on(previous.shutdown());
        }
        let node = runtime()
            .block_on(P2pNode::start(cfg, true))
            .map_err(|e| e.to_string())?;
        let info = node.node_info();
        *node_slot()
            .lock()
            .map_err(|_| "mutex poisoned".to_string())? = Some(node);
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
        // Never hash on the caller's (UI) thread: register by reference now and
        // let the hash be computed in the background, or by the first pull.
        let info = node
            .register_file_deferred(req.item_id, req.path)
            .map_err(|e| e.to_string())?;
        let item_id = info.item_id.clone();
        runtime().spawn(async move {
            if let Err(err) = node.ensure_hashed(&item_id).await {
                tracing::warn!("hashing shared file {item_id} failed: {err}");
            }
        });
        Ok(info)
    })();
    to_c_json(res)
}

#[derive(Deserialize)]
struct AuthorizeTokenReq {
    item_id: String,
    token: String,
    expires_at: DateTime<Utc>,
    #[serde(default)]
    requester_node_id: Option<String>,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dropdrawer_p2p_authorize_token(req_json: *const c_char) -> *mut c_char {
    let res = (|| -> Result<_, String> {
        let node = current_node()?;
        let raw = unsafe { parse_c_str(req_json)? };
        let req: AuthorizeTokenReq = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
        node.authorize_token_for(req.item_id, req.token, req.expires_at, req.requester_node_id);
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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dropdrawer_p2p_download_file(req_json: *const c_char) -> *mut c_char {
    let res = (|| -> Result<_, String> {
        let node = current_node()?;
        let raw = unsafe { parse_c_str(req_json)? };
        let req: DownloadFileReq = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
        let transfer = node.transfers.begin(req.item_id.clone(), None);
        let id = transfer.progress.transfer_id.clone();
        runtime().spawn(async move {
            let _ = node.run_download(transfer, req).await;
        });
        Ok(id)
    })();
    to_c_json(res)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dropdrawer_p2p_cancel_transfer(transfer_id: *const c_char) -> *mut c_char {
    let res = (|| -> Result<_, String> {
        let node = current_node()?;
        let id = unsafe { parse_c_str(transfer_id)? };
        node.transfers.cancel(&id);
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
