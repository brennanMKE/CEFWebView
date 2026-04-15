// CEFHelper - General purpose helper executable for CEF subprocesses
// Handles GPU, utility, and network processes
// Detects process type from command-line arguments (--type=<role>)

#include "include/cef_api_hash.h"
#include "include/capi/cef_app_capi.h"
#include <stdio.h>

int main(int argc, char* argv[]) {
    // Verify CEF API compatibility
    cef_api_hash(CEF_API_VERSION, 0);

    // Log process startup for debugging
    fprintf(stderr, "CEFHelper started with %d arguments\n", argc);
    for (int i = 0; i < argc; i++) {
        fprintf(stderr, "  argv[%d]: %s\n", i, argv[i]);
    }

    // Set up CEF main arguments from command line
    cef_main_args_t args = { .argc = argc, .argv = argv };

    // Execute CEF subprocess
    // CefExecuteProcess will:
    // 1. Detect the subprocess role from argv (--type=renderer, --type=gpu-process, etc.)
    // 2. Run the appropriate subprocess logic
    // 3. Return >= 0 on success (exit code)
    // 4. Return < 0 if this is NOT a subprocess (shouldn't happen here)
    int result = cef_execute_process(&args, NULL, NULL);

    fprintf(stderr, "CEFHelper exiting with code %d\n", result);
    return result;
}
