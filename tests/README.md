Run `ruby tests/deployment_test.rb` with Ruby and the `minitest` gem installed.

The tests run the real `depot update aviary` command in temporary home
directories. Shell commands and HTTP responses are simulated at their external
boundaries; no real sudo, Docker, Tailscale, Git, or service requests run.

Aviary updates keep the shared HTTPS listener running and update only its root
route. Unrelated paths and ports retain their routes and public/private access.
An update refuses to replace another root service or TCP listener, or expose
private neighboring paths. Failure to update an existing Funnel never falls
back to disabling its public access. A new standalone server without Funnel
permission retains the tailnet-only setup.
