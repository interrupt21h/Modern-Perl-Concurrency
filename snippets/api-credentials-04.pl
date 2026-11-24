# Excerpt from refresh(): $ROTATE is the Lua source below.
my $outcome =
    SessionLab::Redis->run_script( $ROTATE, 3, "rt:{$family}:$old_h",
    "rtfam:{$family}", "rt:{$family}:$new_h",
    $new_h, $GRACE_MS, $REFRESH_TTL, );
