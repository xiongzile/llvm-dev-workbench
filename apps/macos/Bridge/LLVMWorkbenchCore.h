#ifndef LLVM_WORKBENCH_CORE_H
#define LLVM_WORKBENCH_CORE_H
// Direct in-process Core API; both CLI and SwiftUI use the same Rust library.
char *llvmwb_request(const char *request_json);
void llvmwb_free(char *response_json);
#endif
