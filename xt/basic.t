#!perl

use IPC::Unix;
use Test::More;

note explain ( IPC::Unix->new(qw(git version)) );
note explain ( IPC::Unix->new(qw(git version))->dup("1>&2") );
note explain ( IPC::Unix->new(qw(git version))->dup("1>&2", "<&-") );
note explain ( IPC::Unix->new(qw(git version))->dup("1>&2")->dup(\*STDIN, "<&", undef) );

open my $null, '+>', "/dev/null";
note explain ( IPC::Unix->new(qw(git name-rev
	--annotate-stdin))->dup("<", $fin)->dup(">", $fout)->dup("2>&", $null) );
note explain ( IPC::Unix->new(qw(git name-rev
	--annotate-stdin))->dup("<", $fin)->dup(">", $fout)->dup("2+>/dev/null") );

note explain ( IPC::Unix->new(qw(git name-rev
	--annotate-stdin))->dup("<", $fin)->dup(">", $fout)->dup("2+>/dev/null")
	->chdir("/path/to/.git")->chdir("annex") );

my $chld = IPC::Unix->new(qw(git version))->dup("1>&2");
my $pid = $chld->spawn;
$chld->wait();
$chld->ok();


ok 1;
done_testing;
