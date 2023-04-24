let () = Random.self_init ()

let sleepf seconds =
  let t = Domain_local_await.prepare_for_await () in
  let cancel = Domain_local_timeout.set_timeoutf seconds t.release in
  try t.await ()
  with exn ->
    cancel ();
    raise exn

let () =
  let n = 100 in
  let port = Random.int 1000 + 3000 in
  Printf.printf "Port %d\n%!" port;
  let server_addr = Unix.ADDR_INET (Unix.inet_addr_loopback, port) in
  Qsched.run @@ fun () ->
  Printf.printf "Client server test\n%!";
  let server =
    Qsched.Task.spawn @@ fun () ->
    Printf.printf "  Server running\n%!";
    let client, _client_addr =
      let socket = Unix.socket PF_INET SOCK_STREAM 0 in
      Fun.protect ~finally:(fun () -> Unix.close socket) @@ fun () ->
      Unix.bind socket server_addr;
      Unix.listen socket 1;
      Printf.printf "  Server listening\n%!";
      Io.accept ~timeout:0.01 socket
    in
    Fun.protect ~finally:(fun () -> Unix.close client) @@ fun () ->
    Printf.printf "  Server accepted client\n%!";
    let bytes = Bytes.create n in
    let n = Io.read client bytes 0 (Bytes.length bytes) in
    Printf.printf "  Server read %d\n%!" n;
    let n = Io.write client bytes 0 (n / 2) in
    Printf.printf "  Server wrote %d\n%!" n
  in
  let client =
    Qsched.Task.spawn @@ fun () ->
    Printf.printf "  Client running\n%!";
    let socket = Unix.socket PF_INET SOCK_STREAM 0 in
    Fun.protect ~finally:(fun () -> Unix.close socket) @@ fun () ->
    Unix.connect socket server_addr;
    Printf.printf "  Client connected\n%!";
    let bytes = Bytes.create n in
    let n = Io.write socket bytes 0 (Bytes.length bytes) in
    Printf.printf "  Client wrote %d\n%!" n;
    let n = Io.read socket bytes 0 (Bytes.length bytes) in
    Printf.printf "  Client read %d\n%!" n
  in
  try
    Qsched.Task.await server;
    Qsched.Task.await client
  with exn -> Printf.printf "Failed with %s\n%!" @@ Printexc.to_string exn

let () =
  Qsched.run @@ fun () ->
  Printf.printf "\nFile read test\n%!";
  let fd = Unix.openfile "test.ml" [ Unix.O_RDONLY ] 0o400 in
  let bytes = Bytes.create 100 in
  let n = Io.read fd bytes 0 100 in
  Printf.printf "  %d\n%!" n;
  Printf.printf "  %s\n\n%!"
    (Bytes.to_string bytes |> String.split_on_char '\n' |> String.concat "\n  ")

let () =
  Printf.printf "The answer is %d!\n%!"
  @@ Qsched.run
  @@ fun () ->
  let child_5 =
    Qsched.Task.spawn @@ fun () ->
    sleepf 0.5;
    13
  in
  let child_2 =
    Qsched.Task.spawn @@ fun () ->
    sleepf 0.2;
    20
  in
  sleepf 0.1;
  9 + Qsched.Task.await child_5 + Qsched.Task.await child_2
