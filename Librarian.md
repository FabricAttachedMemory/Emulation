# Configuring and running The Librarian

## Networking and DNS to the "nodes"

With resolvconf, NetworkManager, and systemd-resolved all vying for attention,
this is highly non-deterministic :-)   More will be revealed...

For now, node01 == 192.168.42.1, node02 == 192.168.42.2, etc.

You can ssh to the node as the "l4tm" user.  If you set your $HOME/.ssh/config
file correctly using the id_rsa.nophrase private key the ssh occurs without
further typing.

## ToRMS: Top-of-Rack Management Server
