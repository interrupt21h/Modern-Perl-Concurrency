use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use SessionLab;

# apply_default_middlewares wraps the app in Plack::Middleware::ReverseProxy
# only for requests from 127.0.0.1, unless using_frontend_proxy is configured
# (see SessionLab.pm). It makes $c->req->secure and the client address
# reflect X-Forwarded-Proto / X-Forwarded-For.
SessionLab->apply_default_middlewares(SessionLab->psgi_app);
