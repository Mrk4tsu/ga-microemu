#!/usr/bin/env python3
"""Fetch the pinned miniJVM and force the interpreter on every build host."""
import argparse
from pathlib import Path
import subprocess

REVISION = "76f904ea4008a8058db5155bf5ee2cfe94d19e60"
IOS = Path(__file__).resolve().parents[1]


def prepare(destination):
    destination = destination.resolve()
    if not (destination / ".git").exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", str(destination)], check=True)
        subprocess.run(["git", "-C", str(destination), "remote", "add", "origin",
                        "https://github.com/digitalgust/miniJVM.git"], check=True)
        subprocess.run(["git", "-C", str(destination), "fetch", "--depth", "1", "origin", REVISION], check=True)
        subprocess.run(["git", "-C", str(destination), "checkout", "--detach", "FETCH_HEAD"], check=True)
    revision = subprocess.check_output(["git", "-C", str(destination), "rev-parse", "HEAD"], text=True).strip()
    if revision != REVISION:
        raise RuntimeError("miniJVM revision mismatch: " + revision)
    header = destination / "minijvm/c/jvm/jit.h"
    text = header.read_text(encoding="utf-8")
    old = "#if __JVM_OS_IOS__ || __JVM_OS_CYGWIN__ || __JVM_ARCH_32__\n#define JIT_ENABLE 0\n#else\n#define JIT_ENABLE 01\n#endif"
    new = "/* MicroEmu iOS: interpreter only, including host compatibility tests. */\n#define JIT_ENABLE 0"
    if old in text:
        header.write_text(text.replace(old, new, 1), encoding="utf-8")
    elif new not in text:
        raise RuntimeError("Pinned JIT configuration changed unexpectedly")
    # Process creation is unavailable in the iOS SDK and outside the MIDP profile.
    posix = destination / "minijvm/c/jvm/os_posix.c"
    text = posix.read_text(encoding="utf-8")
    marker = "/* MicroEmu iOS: no subprocesses in the app sandbox. */"
    if marker not in text:
        start = text.index("s32 os_execute(")
        body = text.index("{", start) + 1
        end = text.index("\ns32 os_kill_process", body)
        close = text.rfind("}", body, end)
        text = text[:body] + "\n" + marker + "\n#if __JVM_OS_IOS__\n    exception_throw(JVM_EXCEPTION_IO, runtime, NULL);\n    return RUNTIME_STATUS_EXCEPTION;\n#else\n" + text[body:close] + "\n#endif\n" + text[close:]
        posix.write_text(text, encoding="utf-8")
    # Thread.exit() can acquire a monitor after miniJVM's first exit cleanup.
    # Release on the owning OS thread before its metadata is destroyed.
    utility = destination / "minijvm/c/jvm/jvm_util.c"
    text = utility.read_text(encoding="utf-8")
    old_exit = "    runtime->thrd_info->thread_status = THREAD_STATUS_ZOMBIE;\n    jthread_assert_no_owned_locks(runtime->thrd_info);"
    new_exit = "    jthread_release_all_owned(runtime); /* MicroEmu: also clean Thread.exit() monitors. */\n" + old_exit
    if new_exit not in text:
        if text.count(old_exit) != 1:
            raise RuntimeError("Thread-exit compatibility patch no longer matches")
        utility.write_text(text.replace(old_exit, new_exit, 1), encoding="utf-8")
    network = destination / "minijvm/c/jvm/jni_io.c"
    text = network.read_text(encoding="utf-8")
    connect = "        ret = mbedtls_net_connect(ctx, jarray_body(host), jarray_body(port), proto);"
    logged = connect + '\n        jvm_printf("[NET] connect %s:%s result=%d\\n", jarray_body(host), jarray_body(port), ret);'
    if logged not in text:
        if text.count(connect) != 1:
            raise RuntimeError("Network diagnostic patch no longer matches")
        network.write_text(text.replace(connect, logged, 1), encoding="utf-8")
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=IOS / ".deps/miniJVM")
    print(prepare(parser.parse_args().runtime))
