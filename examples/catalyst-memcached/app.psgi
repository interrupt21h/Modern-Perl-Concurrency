use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use MemcachedLab;
MemcachedLab->psgi_app;
