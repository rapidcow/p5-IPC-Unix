#!perl

use IPC::Unix;
use Test::More;

note explain ( IPC::Unix->new(qw(git version)) );
note explain ( IPC::Unix->new(qw(git version))->dup("1>&2") );

ok 1;
done_testing;
