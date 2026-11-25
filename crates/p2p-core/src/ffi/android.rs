use std::sync::OnceLock;

use jni::JNIEnv;
use jni::objects::{GlobalRef, JObject};
use jni::sys::{JNI_FALSE, JNI_TRUE, jboolean};

use super::{current_node, runtime};

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_dropdrawer_dropdrawer_1app_DropDrawerApplication_initializeP2pDns(
    env: JNIEnv,
    application: JObject,
) -> jboolean {
    static APPLICATION: OnceLock<GlobalRef> = OnceLock::new();
    let (Ok(vm), Ok(context)) = (env.get_java_vm(), env.new_global_ref(application)) else {
        return JNI_FALSE;
    };
    APPLICATION.get_or_init(|| {
        // Both pointers must outlive every endpoint, including after logout/login.
        unsafe {
            iroh::dns::install_android_jni_context(
                vm.get_java_vm_pointer().cast(),
                context.as_obj().as_raw().cast(),
            );
        }
        context
    });
    JNI_TRUE
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_dropdrawer_dropdrawer_1app_DropDrawerApplication_notifyP2pNetworkChange(
    _env: JNIEnv,
    _application: JObject,
) {
    if let Ok(node) = current_node() {
        runtime().spawn(async move { node.endpoint.network_change().await });
    }
}
