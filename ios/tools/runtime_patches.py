"""Guarded, repeatable compatibility changes against the pinned miniJVM."""
from pathlib import Path


def replace(path, old, new):
    text = path.read_text(encoding="utf-8")
    if new in text:
        return
    if text.count(old) != 1:
        raise RuntimeError("miniJVM patch no longer matches: " + str(path) + " / " + old[:65])
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def apply(runtime):
    # Share the existing plain/encrypted archive opener with the bounded stream adapter.
    replace(runtime / "minijvm/c/utils/miniz_wrapper.c",
        "static mz_bool gemu_zip_reader_open(mz_zip_archive *archive, const char *jarpath) {",
        "/* MicroEmu: shared streaming ZIP opener. */\nmz_bool gemu_zip_reader_open(mz_zip_archive *archive, const char *jarpath) {")
    java = runtime / "minijvm/java/src/main/java/java/lang"
    for signature in (
        "public Method getMethod(String name, Class<?>... parameterTypes) throws NoSuchMethodException {",
        "public Method getDeclaredMethod(String name, Class<?>... parameterTypes) throws NoSuchMethodException {",
        "public Constructor<T> getConstructor(Class<?>... parameterTypes) throws NoSuchMethodException {",
        "public Constructor<T> getDeclaredConstructor(Class<?>... parameterTypes) throws NoSuchMethodException {",
    ):
        replace(java / "Class.java", signature,
                signature + "\n        if (parameterTypes == null) parameterTypes = new Class<?>[0]; // MicroEmu: null means no parameters.")
    # Cancelled threads must still detach from their ThreadGroup and clear roots,
    # without calling application-installed ThreadLifeHandler code during teardown.
    thread = java / "Thread.java"
    source = thread.read_text(encoding="utf-8")
    if "private void microemuExit()" not in source:
        start = source.index("    private void exit() {")
        end = source.index("\n    /**", start)
        body = source[start:end]
        group = body.index("        if (group != null)")
        clean = "    private void microemuExit() {\n" + body[group:]
        thread.write_text(source[:end] + "\n" + clean + source[end:], encoding="utf-8")
    core = runtime / "minijvm/c/jvm"
    replace(core / "jvm.h", "    Instance *context_classloader;",
        "    Instance *context_classloader;\n    u64 microemu_session; /* Immutable host owner, independent of CCL. */\n"
        "    volatile u8 *microemu_cancelled;\n    u8 microemu_exiting;")
    util = core / "jvm_util.c"
    replace(util, "    runtime->thrd_info->context_classloader = parent->thrd_info->context_classloader; //copy context classloader",
        "    runtime->thrd_info->microemu_session = parent->thrd_info->microemu_session;\n"
        "    runtime->thrd_info->microemu_cancelled = parent->thrd_info->microemu_cancelled;\n"
        "    runtime->thrd_info->is_stop = parent->thrd_info->is_stop ||\n"
        "        (parent->thrd_info->microemu_cancelled && *parent->thrd_info->microemu_cancelled);\n"
        "    runtime->thrd_info->context_classloader = parent->thrd_info->context_classloader; //copy context classloader")
    replace(util, '    utf8_append_c(methodName, "exit");',
        "    runtime->thrd_info->microemu_exiting = 1; /* Host-only exit cleanup cannot be cancelled. */\n"
        '    utf8_append_c(methodName, runtime->thrd_info->microemu_session ? "microemuExit" : "exit");')
    # Check at backward branches and native/Java method entry. ERROR has no Java
    # exception object, so even catch(Throwable) cannot swallow cancellation.
    interpreter = core / "interpreter.c"
    replace(interpreter, "#define check_gc_pause(offset){\\\n",
        "#define check_gc_pause(offset){\\\n"
        "    if (!r->thrd_info->microemu_exiting && (r->thrd_info->is_stop || (r->thrd_info->microemu_cancelled && *r->thrd_info->microemu_cancelled))) {\\\n"
        "        r->thrd_info->is_stop = 1; r->stack->sp = sp; ret = RUNTIME_STATUS_ERROR; goto label_exit_while;\\\n"
        "    }\\\n")
    replace(interpreter, "    if (offset < 0 && r->thrd_info->suspend_count) {\\\n",
        "    if (offset <= 0 && r->thrd_info->suspend_count) { /* Include a self-loop (goto 0). */\\\n")
    # Existing is_stop checks are also used by native waits and monitor unwind.
    replace(interpreter, "    r = runtime_create_inl(pruntime);\n",
        "    r = runtime_create_inl(pruntime);\n"
        "    if (!r->thrd_info->microemu_exiting && r->thrd_info->microemu_cancelled && *r->thrd_info->microemu_cancelled)\n"
        "        r->thrd_info->is_stop = 1;\n")
    io = core / "jni_io.c"
    replace(io, "} VmSock;", "} VmSock;\n\n#include \"microemu_session_io.inc\"")
    (core / "microemu_session_io.inc").write_text(
        (Path(__file__).resolve().parents[1] / "native/session_io.inc").read_text(encoding="utf-8"), encoding="utf-8")
    replace(io, "    mbedtls_net_init(ctx);\n    jthread_block_exit(runtime);",
        "    mbedtls_net_init(ctx);\n    if (microemu_io_track(runtime, vmarr) != 0) {\n"
        "        jthread_block_exit(runtime); return exception_throw_out_of_memory(runtime);\n    }\n    jthread_block_exit(runtime);")
    replace(io, "    mbedtls_net_free(ctx);\n#if _JVM_DEBUG_LOG_LEVEL > 5",
        "    microemu_io_close(runtime->jvm, vmarr);\n#if _JVM_DEBUG_LOG_LEVEL > 5")
    replace(io, "        gc_obj_release(runtime->jvm->collector, cltarr);\n        push_ref(runtime->stack, ret < 0 ? NULL : cltarr);",
        "        gc_obj_release(runtime->jvm->collector, cltarr);\n"
        "        if (ret >= 0 && microemu_io_track(runtime, cltarr) != 0) {\n"
        "            mbedtls_net_free(&cltsock->contex); ret = -1;\n        }\n"
        "        if (ret >= 0) microemu_io_ready(cltarr);\n        push_ref(runtime->stack, ret < 0 ? NULL : cltarr);")
    replace(io, '        jvm_printf("[NET] connect %s:%s result=%d\\n", jarray_body(host), jarray_body(port), ret);',
        '        jvm_printf("[NET] connect %s:%s result=%d\\n", jarray_body(host), jarray_body(port), ret);\n'
        '        if (ret == 0) microemu_io_ready(vmarr);')
    replace(io, "            if (runtime->thrd_info->is_interrupt) {\n                //vm notify thread destroy",
        "            if (runtime->thrd_info->is_interrupt || runtime->thrd_info->is_stop) {\n                // MicroEmu: cancel accept for this session.")
    replace(core / "jvm.c", "    gc_destroy(jvm);",
        "    extern void microemu_io_release(MiniJVM *, u64);\n"
        "    microemu_io_release(jvm, 0); /* Drop session roots before destroying the heap. */\n    gc_destroy(jvm);")
    replace(core / "jni_std.c", "    //exit(status);\n    runtime->jvm->collector->exit_flag = 1;",
        "    // MicroEmu: a game can exit its own session, never the shared VM.\n"
        "    if (runtime->thrd_info->microemu_session) {\n"
        "        if (runtime->thrd_info->microemu_cancelled) *runtime->thrd_info->microemu_cancelled = 1;\n"
        "        runtime->thrd_info->is_stop = 1; return RUNTIME_STATUS_ERROR;\n    }\n"
        "    //exit(status);\n    runtime->jvm->collector->exit_flag = 1;")
