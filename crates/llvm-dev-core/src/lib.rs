//! Shared application core. Neither frontend composes CMake commands or owns build processes.
mod ide;
mod operations;
mod workspace;

pub use operations::{cancel_all, dispatch};
pub use workspace::*;

use std::ffi::{c_char, CStr, CString};

/// In-process library boundary. A JSON envelope carries domain records, not CLI output.
/// The caller owns the returned allocation and releases it with llvmwb_free.
#[no_mangle]
pub unsafe extern "C" fn llvmwb_request(input: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if input.is_null() {
            return Err("Null request".to_string());
        }
        let text = CStr::from_ptr(input).to_str().map_err(|e| e.to_string())?;
        let request = serde_json::from_str(text).map_err(|e| format!("Invalid request: {e}"))?;
        dispatch(request)
    });
    let envelope = match result {
        Ok(Ok(data)) => serde_json::json!({"ok": true, "data": data, "schema": 1}),
        Ok(Err(error)) => serde_json::json!({"ok": false, "error": error, "schema": 1}),
        Err(_) => serde_json::json!({"ok": false, "error": "Internal core error", "schema": 1}),
    };
    CString::new(envelope.to_string()).unwrap().into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn llvmwb_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}
