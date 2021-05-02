# Avalanche Remote Access

Port 9650 is used to access the [Avalanche JSON API](https://docs.avax.network/build/avalanchego-apis/issuing-api-calls), and it is restricted to localhost by default. Rightly so: you don't want to allow anyone to play at will with your node.

It means you have to ssh into your node in order to call these methods. You can use OpenSSH's `-L` flag or Putty's equivalent port forwarding capabilities to access it from the comfort of your own workstation, but that's clumsy, and moreover it's out of reach for most non-technical users. 

Also, you might want a web application server to be able to connect to an Avalanche back-end located on a different machine, without having to deal with IP address authorization chores. Other applications are left to your imagination. 

OK. Let's open the service the secure way. Let's use a client certificate to access an Apache HTTPS server, and have it signed by a certification authority. Oh yeah, let's have a [PKI](https://en.wikipedia.org/wiki/Public_key_infrastructure). 

Because we can.

Now we have a [P12/PFX](https://en.wikipedia.org/wiki/PKCS_12) file containing a client certificate and its associated private key, and a web server certificate and key: both parties can communicate safely using two-way authentication through a properly configured Apache web server. This web server accepts requests on port 19650 from remote clients providing correct credentials, and transfers them to the Avalanche API, passing back the returned values.

All of this is actually a bit complicated to set up, which is why I wrote [an install script](https://raw.githubusercontent.com/jzu/ara/main/install-ara.sh) for Ubuntu to spare users the gory details. It configures an Apache CGI/SSL reverse proxy to the Avalanche JSON API, generates X.509v3 certificates for secure remote communication, and creates a virtual host configuration file and a CGI wrapper. There's an uninstall option to remove the virtual host from the Apache configuration.

At first, I thought I could use some flavour of mod\_proxy but kept running into issues, so I switched to a CGI wrapper script. Ungainly, but functional; inefficient, but who cares. And we don't really have a PKI, not even a full CA, because we only need to sign certificates. Should you need to change them, just uninstall/reinstall with the script and _voilà_, you get new certificates--the former ones become invalid.


## Example

Using Curl to access the `health.getLiveness` method on a node named `my-avalanche-node`, you would add the SSL/TLS-related flags and change the URL:

    curl --data '{ 
           "jsonrpc": "2.0", 
           "id":      1, 
           "method": "health.getLiveness"
           }' \
         -H 'content-type:application/json;' \
         -k --cert-type P12 -E /tmp/api.p12 \
         https://my-avalanche-node:19650/ext/health

Or, with [`bac`](https://github.com/jzu/bac), you can create a configuration file named `bacara.conf` in `$HOME/.config` containing two directives: `URI` for the remote host and port, prefixed with `https://`, and `P12` for the authentication file. For instance:

    URI=https://my-avalanche-node:19650
    P12=/tmp/api.p12

Instead of querying the local node, `bac` will connect to the remote host using the exact same syntax as before:

    bac -f health.getLiveness

