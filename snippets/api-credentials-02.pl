my ( $header, $claims ) = decode_jwt(
    token         => $jwt,
    key           => $JWT_KEY,
    accepted_alg  => 'HS256',    # never trust the token's own alg header
    verify_exp    => 1,    # REQUIRE exp, do not merely check it if present
    verify_iss    => $ISSUER,
    verify_aud    => $AUDIENCE,
    leeway        => 30,    # small clock skew between servers
    decode_header => 1,
);
die "not an access token\n" unless lc( $header->{typ} // '' ) eq 'at+jwt';
