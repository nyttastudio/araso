# Input-server launch and switching checks (macOS)

An IMK server that cannot be relaunched can leave applications waiting for an input endpoint.
`--register`, a successful bundle self-test, a settings window, and a successful
`TISSelectInputSource` call are each insufficient evidence of working typing.

`scripts/install.sh` launches the installed app through LaunchServices and requires a reply from
the warmed-up server's main run loop. Do not substitute a shell-owned foreground `Araso` process:
it can hide a broken system launch and disappear when its terminal/tool session ends.
An explicit LaunchServices launch can also succeed while IMK's automatic launch fails: the
installer probe does not replace the cold-launch and relaunch checks below.

For a user installation, check the already-running server with:

```sh
"$HOME/Library/Input Methods/Araso.app/Contents/MacOS/Araso" --check-server
```

For a package installation, use `/Library/Input Methods/Araso.app/Contents/MacOS/Araso`.
Only the IMK-server execution path registers a responder after creating the server and loading
its models. The probe has a five-second timeout and requires the same canonical bundle path
and a fresh request token. It neither launches nor selects anything. It is a diagnostic,
not a security boundary or an end-to-end typing test.

## Automated checks

```sh
swift test
swiftc Sources/Araso/InputServerHealth.swift scripts/tests/input-server-health.swift -o /tmp/araso-health-test
/tmp/araso-health-test
```

The IPC tests cover no server, a settings-like process without a responder, a responsive server,
a different bundle path, a blocked main run loop, recovery, termination, and restart.
They use their own processes and temporary identities, without selecting an input source.

## Installed-app checks

Keep a built-in source available throughout. Use an empty test document, without recording
the screen or logging typed text. Restore the user's previous source after checking.

1. With no Araso process running, select Araso in the input menu and type `dkssud hello `.
   Confirm `안녕 hello `, a successful `--check-server`, and a system-launched server process.
   Starting the executable directly to make this pass invalidates the cold-launch check.
2. Switch to 2-Set Korean and type `dkssud `; confirm `안녕 `. Switch to U.S. and confirm `hello `.
3. Select Araso again. Open and cancel an accent menu, then switch sources while a letter is
   pending and while the menu is visible. The menu must disappear and the next source must type.
4. Switch to a built-in source, terminate only the Araso server, and select Araso again. Repeat
   step 1 to check relaunch. Also check opening/closing Settings does not stop the input server.
5. Separately check after display off/on and after login. Automated key presses do not establish
   that a physical held key generates the expected repeat events.

If macOS logs `LaunchInputMethod() Error, status=-50` or `NO Endpoint`, keep the built-in source
selected. Re-add the installed source or log out and back in to refresh the session's IMK state.
Do not report the problem resolved merely because a manually launched server types once.
