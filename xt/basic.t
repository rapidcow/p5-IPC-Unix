#!perl

use IPC::Unix;
use Test::More;

note explain ( IPC::Unix->new(qw(git version)) );
note explain ( IPC::Unix->new(qw(git version))->dup("1>&2") );
note explain ( IPC::Unix->new(qw(git version))->dup("1>&2", "<&-") );
note explain ( IPC::Unix->new(qw(git version))->dup("1>&2")->dup(\*STDIN, "<&", undef) );

open my $null, '+>', "/dev/null";
note explain ( IPC::Unix->new(qw(git name-rev
	--annotate-stdin))->dup("<|", $fin)->dup(">|", $fout)->dup("2>&", $null) );
note explain ( IPC::Unix->new(qw(git name-rev
	--annotate-stdin))->dup("<|", $fin)->dup(">|", $fout)->dup("2+>/dev/null") );

note explain ( IPC::Unix->new(qw(git name-rev
	--annotate-stdin))->dup("<|", $fin)->dup(">|", $fout)->dup("2+>/dev/null")
	->chdir("/path/to/.git")->chdir("annex") );

$IPC::Unix::TRACE++;
my $chld = IPC::Unix->new(qw(git version))->dup("1>&2");
my $pid = $chld->spawn;
$chld->wait();
$chld->ok();

$chld = IPC::Unix->new(qw(git mktree))->dup(*STDOUT, ">|", my $fh, "<&-");
$chld->spawn;
chomp (my $emptytree = <$fh>);
$chld->wait();
$chld->ok();

note "Empty tree: ", $emptytree;

$chld = IPC::Unix->new(qw(git diff --quiet), $emptytree, HEAD);
$chld->spawn;
$chld->wait();
eval { $chld->ok(); }; diag "ok? $@";

$chld = IPC::Unix->new(qw(git mktree))->dup("<&-", ">|", my $fh);
$chld->spawn;
chomp ($emptytree = <$fh>);
$chld->wait();
$chld->ok();

print "An empty tree: $emptytree\n";

ok 1;
done_testing;
