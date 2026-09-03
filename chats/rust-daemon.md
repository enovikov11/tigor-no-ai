
Товарищи rust-о-маны и сесурити инженеры, пожалуйста помогите проверить код и поделитесь советом

Вот я запустил этот код под root, чтобы он мог привелегированно выполнять фиксированные команды

coproc P { podman run --rm -i --user 1000:100 some-telegram-bot; }
exec ./rust-program <&"${P[0]}" >&"${P[1]}"

Существует ли такой input, через который можно получить unrestricted RCE? И даже если нет, есть ли рекомендации как лучше писать кроме как вот так:

use std::{
    io::{self, BufRead, Write},
    process::{Command, Stdio},
    thread,
    time::{SystemTime, UNIX_EPOCH},
};

fn cmd(s: &str) -> Option<(&'static str, &'static [&'static str])> {
    Some(match s {
        "/sync" => ("sync", &[]),
        "/reboot" => ("reboot", &["now"]),
        "/run-vm" => ("virsh", &["start", "vmname"]),
        "/foo" => ("systemctl", &["restart", "foo.service"]),
        "/honk" => ("sh", &["-c", "echo o > /proc/sysrq-trigger"]),
        _ => return None,
    })
}

fn main() {
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let Some((prog, args)) = cmd(&line) else { continue };

        thread::spawn(move || {
            let id = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_millis();

            println!("{id} started");
            let _ = io::stdout().flush();

            let result = Command::new(prog)
                .args(args)
                .stdin(Stdio::null())
                .status();

            match result {
                Ok(s) => println!("{id} exited {}", s.code().unwrap_or(-1)),
                Err(e) => println!("{id} error {e}"),
            }
        });
    }
}

```rust
use std::{
    // `io` gives access to stdin/stdout and general I/O facilities.
    //
    // `BufRead` provides the `.lines()` iterator used below.  Locking stdin
    // and reading it through the buffered interface avoids repeatedly taking
    // the stdin lock for every input operation.
    //
    // `Write` is imported specifically so that `stdout().flush()` is
    // available through the `Write` trait.
    io::{self, BufRead, Write},

    // `Command` constructs and launches a child process.
    //
    // IMPORTANT SECURITY PROPERTY:
    //
    // `Command` executes a program directly.  It does NOT implicitly invoke
    // `/bin/sh -c`.
    //
    // Therefore shell syntax has no special meaning here.  For example, an
    // argument containing:
    //
    //     ; rm -rf /
    //
    // would be passed literally as ONE argument if it ever reached Command.
    // It would not become a second shell command.
    //
    // In this particular program the situation is even stronger: no
    // user-controlled string reaches `Command` at all.
    //
    // `Stdio` controls what the child process receives for stdin/stdout/stderr.
    process::{Command, Stdio},

    // Used to run each accepted command concurrently.
    thread,

    // Used only for the log/request ID below.
    //
    // `SystemTime` is wall-clock time, not a monotonic clock, and UNIX_EPOCH
    // is 1970-01-01 00:00:00 UTC.
    time::{SystemTime, UNIX_EPOCH},
};

/// Convert an untrusted input string into one of a small number of explicitly
/// permitted commands.
///
/// SECURITY MODEL
/// --------------
///
/// This function is the main security boundary of the program.
///
/// The caller gives us an arbitrary `&str`, which may be completely
/// attacker-controlled.  We do NOT treat that string as:
///
///   * a shell command,
///   * an executable pathname,
///   * an argument,
///   * an environment variable,
///   * a filename,
///   * or data interpolated into any of those.
///
/// Instead, the string is used exclusively as an exact-match selector into
/// this hard-coded allowlist.
///
/// Consequently:
///
///     "date"
///
/// is accepted, while strings such as:
///
///     "date "
///     "date -R"
///     "date; id"
///     "date && bash"
///     "$(id)"
///     "`id`"
///     "restart foo.service"
///     "../../../bin/sh"
///
/// are rejected.
///
/// This is substantially safer than doing something such as:
///
///     Command::new("sh").arg("-c").arg(s)
///
/// which would explicitly ask a shell to interpret attacker-controlled input.
///
/// It is also safer than:
///
///     Command::new(s)
///
/// because that would let the caller choose the executable.
///
/// RETURN TYPE
/// -----------
///
/// The return value is:
///
///     Option<(&'static str, &'static [&'static str])>
///
/// `Option` means:
///
///     Some(...)  -> input corresponds to an allowed operation
///     None       -> input is not allowed
///
/// Both the program name and arguments have `'static` lifetimes because all
/// strings returned here are string literals compiled into the executable.
/// They therefore do not borrow anything from `s`.
///
/// This matters later when the values are moved into a newly spawned thread:
/// the spawned thread is allowed to outlive this function call, so borrowed
/// data tied to `s` would generally not be suitable.  `'static` literals are.
fn cmd(s: &str) -> Option<(&'static str, &'static [&'static str])> {
    // The somewhat compact construction:
    //
    //     Some(match s { ... })
    //
    // means:
    //
    //   1. Match the input.
    //   2. For a recognized input, produce `(program, arguments)`.
    //   3. Wrap that tuple in `Some`.
    //
    // The `_ => return None` arm exits the entire `cmd()` function
    // immediately, so an unknown string is never wrapped in `Some`.
    Some(match s {
        // Exact input:
        //
        //     date
        //
        // results in execution conceptually equivalent to:
        //
        //     exec("date", ["date"])
        //
        // rather than:
        //
        //     sh -c "date"
        //
        // No arguments are supplied.
        //
        // SECURITY CAVEAT:
        // "date" is not an absolute pathname.  The OS/Rust runtime therefore
        // resolves it using normal executable lookup semantics, generally
        // involving PATH on Unix.
        //
        // If an attacker can control the daemon's PATH, or can write an
        // executable called `date` into a directory that appears earlier in
        // PATH, that attacker may be able to make this execute their program.
        //
        // That is NOT command injection through `s`, but it is an important
        // environmental RCE possibility.
        "date" => ("date", &[]),

        // Likewise executes the fixed program "uptime" with no arguments.
        //
        // Again, stdin cannot change the executable or arguments, but PATH
        // resolution remains part of the trust boundary.
        "uptime" => ("uptime", &[]),

        // The only accepted spelling is exactly "uname".
        //
        // The argument "-a" is a static string controlled by the program,
        // not by the input.
        //
        // An input such as:
        //
        //     uname -a; id
        //
        // does NOT partially match "uname"; Rust string-pattern matching here
        // requires equality with the complete string.
        "uname" => ("uname", &["-a"]),

        // Executes:
        //
        //     ls -lah /tmp
        //
        // Both "-lah" and "/tmp" are constants.
        //
        // Therefore there is no opportunity for an attacker to inject another
        // ls option, choose another path, or use a shell metacharacter through
        // stdin.
        //
        // Note that `ls` itself processes whatever filesystem contents exist
        // under /tmp.  Malicious filenames can produce ugly or misleading
        // terminal output (control characters, newlines, escape sequences,
        // etc.), but filenames are not interpreted by a shell here.
        //
        // If this output feeds some other parser rather than a human terminal,
        // treating the output as trusted structured data would be a separate
        // design problem.
        "ls" => ("ls", &["-lah", "/tmp"]),

        // Executes:
        //
        //     systemctl restart foo.service
        //
        // Again, both arguments are fixed.
        //
        // The caller cannot substitute another unit name because the input
        // string merely selects this complete preconstructed operation.
        //
        // HOWEVER:
        //
        // This action may itself be highly privileged.  If this program runs
        // as root, or has authorization through polkit/systemd configuration,
        // an untrusted caller is being granted the ability to restart
        // `foo.service`.
        //
        // That is not arbitrary command injection, but it is still a security
        // capability.  Repeatedly issuing "restart" can cause availability
        // problems, lost requests, state corruption in a poorly designed
        // service, etc.
        //
        // There is also an environmental trust assumption: the definition of
        // `foo.service` must itself be trusted.  If an attacker can modify its
        // systemd unit file, drop-ins, ExecStart target, or related executable,
        // then being able to trigger the restart may become a route to execute
        // whatever that compromised unit specifies.
        "restart" => ("systemctl", &["restart", "foo.service"]),

        // Catch-all arm.
        //
        // Every string not exactly equal to one of the names above reaches
        // this arm.
        //
        // `return None` exits `cmd()` immediately.
        //
        // This is what prevents arbitrary stdin from falling through into
        // process execution.
        _ => return None,
    })
}

fn main() {
    // `io::stdin()` obtains the process's standard-input handle.
    //
    // `.lock()` creates a locked/buffered view of it.  Holding this lock while
    // iterating is more efficient and gives one consistent reader.
    //
    // `.lines()` returns an iterator whose items are:
    //
    //     Result<String, io::Error>
    //
    // Each successfully read logical line becomes its own owned `String`.
    //
    // The terminating newline is removed by the line-reading abstraction, so
    // input:
    //
    //     date\n
    //
    // becomes approximately:
    //
    //     "date"
    //
    // for matching purposes.
    for line in io::stdin().lock().lines() {
        // Rust's `let ... else` syntax destructures the `Result`.
        //
        // Success:
        //
        //     Ok(line)
        //
        // stores the String in `line`.
        //
        // Error:
        //
        //     Err(...)
        //
        // executes the `else` block, which simply terminates the input loop.
        //
        // The I/O error is intentionally ignored here.
        let Ok(line) = line else { break };

        // Run the untrusted line through the allowlist.
        //
        // If the string is not one of:
        //
        //     date
        //     uptime
        //     uname
        //     ls
        //     restart
        //
        // `cmd()` returns None.
        //
        // `continue` then skips the rest of this loop iteration, so no thread
        // and no process is created for rejected input.
        //
        // For accepted input, `prog` and `args` refer exclusively to static
        // string literals selected inside `cmd()`.  They contain no bytes from
        // `line`.
        let Some((prog, args)) = cmd(&line) else { continue };

        // Start a new OS thread for every accepted command.
        //
        // `move` transfers the captured `prog` and `args` values into the
        // closure rather than borrowing the local variables from this loop.
        //
        // Because the underlying strings have `'static` lifetime, they remain
        // valid regardless of how long this thread runs.
        //
        // SECURITY / AVAILABILITY WARNING:
        //
        // There is NO concurrency limit.
        //
        // An attacker who controls stdin can send:
        //
        //     date
        //     date
        //     date
        //     date
        //     ...
        //
        // very quickly and cause this process to create a potentially enormous
        // number of threads and child processes.
        //
        // That probably does not result in RCE, but it is a straightforward
        // denial-of-service vector:
        //
        //   * thread stacks consume virtual/physical memory;
        //   * process creation consumes PIDs and kernel resources;
        //   * CPU usage can spike;
        //   * the machine can hit process/thread limits;
        //   * `restart` can repeatedly disrupt foo.service.
        //
        // For genuinely hostile input, bounded concurrency or a worker pool
        // is strongly preferable.
        thread::spawn(move || {
            // Generate a human-readable ID from the current wall-clock time.
            let id = SystemTime::now()
                // Compute the elapsed duration since the Unix epoch.
                //
                // This returns Result<Duration, SystemTimeError> because a
                // system clock could theoretically be earlier than 1970.
                .duration_since(UNIX_EPOCH)

                // Panic this worker thread if the clock is before UNIX_EPOCH.
                //
                // Normally harmless on a correctly configured modern machine,
                // but using `unwrap()` means unusual clock state can kill the
                // individual worker.
                .unwrap()

                // Convert the duration into whole milliseconds.
                //
                // SECURITY NOTE:
                //
                // This is only a log correlation value.  It is NOT:
                //
                //   * random,
                //   * secret,
                //   * unpredictable,
                //   * guaranteed unique,
                //   * or cryptographically suitable.
                //
                // Two threads can easily obtain the same millisecond and
                // therefore print the same ID.
                //
                // Wall-clock adjustments can also make IDs move backwards.
                .as_millis();

            // Announce that this worker is starting.
            //
            // `println!` writes a line ending to stdout.
            //
            // Since multiple threads and the child processes can all write to
            // stdout concurrently, their output can be interleaved.  This is a
            // logging/observability concern rather than an RCE issue.
            println!("{id} started");

            // Explicitly request that buffered stdout be flushed now.
            //
            // The result is discarded with `let _ = ...`, so a broken pipe or
            // other stdout error does not terminate the operation.
            //
            // This is presumably intended to ensure that "started" appears
            // before a possibly long-running child process finishes.
            let _ = io::stdout().flush();

            // Construct the child process.
            //
            // THIS IS THE MOST SECURITY-SENSITIVE SECTION.
            //
            // `prog` is NOT the original untrusted input.  It is one of:
            //
            //     "date"
            //     "uptime"
            //     "uname"
            //     "ls"
            //     "systemctl"
            //
            // selected by the hard-coded allowlist.
            let result = Command::new(prog)

                // Add each static argument to the child's argv.
                //
                // Rust does not concatenate these into a command-line string
                // and feed that string to a shell.
                //
                // For example:
                //
                //     args(&["restart", "foo.service"])
                //
                // creates separate argv entries analogous to:
                //
                //     argv[0] = "systemctl"
                //     argv[1] = "restart"
                //     argv[2] = "foo.service"
                //
                // There is no shell tokenization stage.
                .args(args)

                // Connect the child's stdin to the null device.
                //
                // This is a useful defensive property here:
                //
                // the launched command cannot continue consuming protocol data
                // from the parent's stdin, accidentally race the main reader,
                // or become an interactive command accepting further attacker
                // input through stdin.
                .stdin(Stdio::null())

                // Launch the command and wait for it to terminate.
                //
                // `.status()` differs from `.output()`:
                //
                // it waits for completion and returns only the exit status;
                // the child's normal stdout/stderr are not collected into a
                // String by this call.
                //
                // Because this waiting happens inside the spawned thread, the
                // main stdin loop remains free to receive more commands.
                .status();

            // `status()` returns:
            //
            //     Result<ExitStatus, io::Error>
            //
            // `Ok` means the child was successfully launched and eventually
            // terminated.
            //
            // `Err` means process creation/execution itself failed, e.g. the
            // executable could not be found or permission was denied.
            match result {
                Ok(s) => {
                    // `s.code()` is Option<i32>.
                    //
                    // Normal process exit:
                    //
                    //     Some(exit_code)
                    //
                    // Termination in a way that does not have an ordinary exit
                    // code, such as a Unix signal:
                    //
                    //     None
                    //
                    // This program maps `None` to -1 solely for logging.
                    println!("{id} exited {}", s.code().unwrap_or(-1))
                }

                // Report an execution error.
                //
                // `{e}` uses the error's Display implementation.
                //
                // Again, this is operational information; no attacker-supplied
                // stdin string is interpolated here.
                Err(e) => println!("{id} error {e}"),
            }
        });

        // The JoinHandle returned by `thread::spawn()` is discarded.
        //
        // Thus the main thread never explicitly joins workers.
        //
        // If stdin reaches EOF, `main()` can finish even while workers are
        // still running.  Terminating the process then terminates those
        // threads and potentially leaves child-process lifecycle behavior
        // dependent on the OS/timing.
        //
        // This is primarily a correctness/lifecycle issue, not command
        // injection.
    }
}
```