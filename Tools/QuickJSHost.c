// Minimal host for yt-dlp's synchronous EJS solver. The JS engine is unmodified;
// scripts get console.log, but no file, network, process or module-loading APIs.
#include "quickjs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}

static int interrupted(JSRuntime *runtime, void *opaque) {
    (void)runtime;
    return now() > *(double *)opaque;
}

static JSValue log_message(JSContext *context, JSValueConst this_value,
                           int count, JSValueConst *arguments) {
    (void)this_value;
    for (int index = 0; index < count; index++) {
        const char *text = JS_ToCString(context, arguments[index]);
        if (!text) return JS_EXCEPTION;
        if (index) putchar(' ');
        fputs(text, stdout);
        JS_FreeCString(context, text);
    }
    putchar('\n');
    return JS_UNDEFINED;
}

int main(int argc, char **argv) {
    if (argc == 2 && (!strcmp(argv[1], "--help") || !strcmp(argv[1], "--version"))) {
        printf("QuickJS-ng version %d.%d.%d\nLeafpick EJS host: --script FILE\n",
               QJS_VERSION_MAJOR, QJS_VERSION_MINOR, QJS_VERSION_PATCH);
        return 0;
    }
    if (argc != 3 || strcmp(argv[1], "--script")) {
        fputs("Usage: qjs --script FILE\n", stderr);
        return 1;
    }
    FILE *file = fopen(argv[2], "rb");
    if (!file) { perror("EJS input"); return 1; }
    if (fseek(file, 0, SEEK_END)) { fclose(file); return 1; }
    long length = ftell(file);
    if (length < 0 || length > 64 * 1024 * 1024 || fseek(file, 0, SEEK_SET)) {
        fclose(file); return 1;
    }
    char *source = malloc((size_t)length + 1);
    if (!source) { fclose(file); return 1; }
    size_t read_count = fread(source, 1, (size_t)length, file);
    fclose(file);
    if (read_count != (size_t)length) { free(source); return 1; }
    source[length] = '\0';

    JSRuntime *runtime = JS_NewRuntime();
    if (!runtime) { free(source); return 1; }
    JS_SetMemoryLimit(runtime, 512 * 1024 * 1024);
    JS_SetMaxStackSize(runtime, 4 * 1024 * 1024);
    double deadline = now() + 90;
    JS_SetInterruptHandler(runtime, interrupted, &deadline);
    JSContext *context = JS_NewContext(runtime);
    if (!context) { JS_FreeRuntime(runtime); free(source); return 1; }
    JSValue global = JS_GetGlobalObject(context);
    JSValue console = JS_NewObject(context);
    JS_SetPropertyStr(context, console, "log", JS_NewCFunction(context, log_message, "log", 1));
    JS_SetPropertyStr(context, global, "console", console);
    JS_FreeValue(context, global);
    JSValue result = JS_Eval(context, source, (size_t)length, "<ejs>", JS_EVAL_TYPE_GLOBAL);
    free(source);
    int status = JS_IsException(result) ? 1 : 0;
    JS_FreeValue(context, result);
    // EJS is synchronous, but settle promise callbacks without introducing host APIs.
    while (!status && JS_IsJobPending(runtime)) {
        if (now() > deadline) { status = 1; break; }
        if (JS_ExecutePendingJob(runtime, &context) < 0) status = 1;
    }
    if (status) {
        JSValue error = JS_GetException(context);
        const char *message = JS_ToCString(context, error);
        fprintf(stderr, "EJS failed: %s\n", message ? message : "runtime limit exceeded");
        JS_FreeCString(context, message);
        JS_FreeValue(context, error);
    }
    JS_FreeContext(context);
    JS_FreeRuntime(runtime);
    return status;
}
