#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'IPC::Unix' ) || print "Bail out!\n";
}

diag( "Testing IPC::Unix $IPC::Unix::VERSION, Perl $], $^X" );
