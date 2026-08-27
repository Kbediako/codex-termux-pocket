#!/usr/bin/env python3
"""Adapt the retained Termux Linux sandbox to the alpha.5 proxy-control API."""

from pathlib import Path

PATH = Path("codex-rs/linux-sandbox/src/linux_run_main.rs")
text = PATH.read_text(encoding="utf-8")

old_outer = '''        let proxy_route_spec = if allow_network_for_proxy {
            let (proxy_route_spec, socket_dir) = prepare_host_proxy_route_spec()
                .unwrap_or_else(|err| panic!("failed to prepare host proxy routing bridge: {err}"));
            file_system_sandbox_policy = file_system_sandbox_policy.with_additional_readable_roots(
                &sandbox_policy_cwd,
                std::slice::from_ref(&socket_dir),
            );
            Some(proxy_route_spec)
        } else {
            None
        };'''
new_outer = '''        let (proxy_route_spec, proxy_controls) = if allow_network_for_proxy {
            let (proxy_route_spec, controls) = prepare_host_proxy_route_spec()
                .unwrap_or_else(|err| panic!("failed to prepare host proxy routing bridge: {err}"));
            (Some(proxy_route_spec), controls)
        } else {
            (None, Vec::new())
        };'''
if text.count(old_outer) != 1:
    raise SystemExit("unexpected proxy-route outer-stage block")
text = text.replace(old_outer, new_outer)

old_call = '''        run_bwrap_with_proc_fallback(
            &sandbox_policy_cwd,
            command_cwd.as_deref(),
            &file_system_sandbox_policy,
            network_sandbox_policy,
            inner,
            !no_proc,
            allow_network_for_proxy,
        );'''
new_call = '''        run_bwrap_with_proc_fallback(
            &sandbox_policy_cwd,
            command_cwd.as_deref(),
            &file_system_sandbox_policy,
            bwrap_network_mode(network_sandbox_policy, allow_network_for_proxy),
            inner,
            proxy_controls,
            !no_proc,
        );'''
if text.count(old_call) != 1:
    raise SystemExit("unexpected bubblewrap call block")
text = text.replace(old_call, new_call)

old_function = '''fn run_bwrap_with_proc_fallback(
    sandbox_policy_cwd: &Path,
    command_cwd: Option<&Path>,
    file_system_sandbox_policy: &FileSystemSandboxPolicy,
    network_sandbox_policy: NetworkSandboxPolicy,
    inner: Vec<String>,
    mount_proc: bool,
    allow_network_for_proxy: bool,
) -> ! {
    let network_mode = bwrap_network_mode(network_sandbox_policy, allow_network_for_proxy);
    let mut mount_proc = mount_proc;'''
new_function = '''fn run_bwrap_with_proc_fallback(
    sandbox_policy_cwd: &Path,
    command_cwd: Option<&Path>,
    file_system_sandbox_policy: &FileSystemSandboxPolicy,
    network_mode: BwrapNetworkMode,
    inner: Vec<String>,
    proxy_controls: Vec<File>,
    mount_proc: bool,
) -> ! {
    let mut mount_proc = mount_proc;'''
if text.count(old_function) != 1:
    raise SystemExit("unexpected bubblewrap function signature")
text = text.replace(old_function, new_function)

old_tail = '''    .unwrap_or_else(|err| exit_with_bwrap_build_error(err));
    apply_inner_command_argv0(&mut bwrap_args.args);
    run_or_exec_bwrap(bwrap_args);'''
new_tail = '''    .unwrap_or_else(|err| exit_with_bwrap_build_error(err));
    bwrap_args.preserved_files.extend(proxy_controls);
    apply_inner_command_argv0(&mut bwrap_args.args);
    run_or_exec_bwrap(bwrap_args);'''
if text.count(old_tail) != 1:
    raise SystemExit("unexpected bubblewrap preserved-file tail")
text = text.replace(old_tail, new_tail)

PATH.write_text(text, encoding="utf-8")
