package SessionLab::Redis;
# One Redis connection per process, created lazily and recreated after fork.
# Preforking servers (Starman, Gazelle, uWSGI) fork workers from a master;
# a socket inherited across fork would be shared by several processes and
# their replies would interleave. Checking $$ makes the handle fork-safe.
use strict;
use warnings;
use Redis;

my ($handle, $owner_pid);

sub handle {
    return $handle if $handle && $owner_pid == $$;
    $handle = Redis->new(
        server        => $ENV{REDIS_SERVER} // '127.0.0.1:6379',
        name          => "sessionlab-$$",          # visible in CLIENT LIST
        cnx_timeout   => 1,
        read_timeout  => 2,
        write_timeout => 2,
        reconnect     => 0,      # never replay SET NX / INCR after a lost reply
        (defined $ENV{REDIS_PASSWORD}
            ? (username => $ENV{REDIS_USERNAME} // 'default',
               password => $ENV{REDIS_PASSWORD}) : ()),
        ($ENV{REDIS_TLS} ? (ssl => 1, SSL_verify_mode => 1) : ()),
    );
    $owner_pid = $$;
    return $handle;
}

# Drop the handle after a network error so the next call reconnects.
sub reset { undef $handle }

# EVALSHA with a one-time SCRIPT LOAD fallback (the script cache is empty
# after a restart or failover).
my %sha;
sub run_script {
    my ($class, $source, @keys_and_args) = @_;
    my $r = $class->handle;
    my $reply = eval {
        $sha{$source} //= $r->script_load($source);
        $r->evalsha($sha{$source}, @keys_and_args);
    };
    return $reply unless $@;
    die $@ unless $@ =~ /NOSCRIPT/;
    $sha{$source} = $r->script_load($source);
    return $r->evalsha($sha{$source}, @keys_and_args);
}

1;
