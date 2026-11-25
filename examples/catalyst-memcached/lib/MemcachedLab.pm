package MemcachedLab;
use Moose;
use namespace::autoclean;
use Catalyst::Runtime 5.80;
use Catalyst;
extends 'Catalyst';
__PACKAGE__->config( name => 'MemcachedLab' );
__PACKAGE__->setup;
1;
