#!perl

use IPC::Unix;
use Test::More;

use POSIX;
no locale;
setlocale(LC_ALL, "C");

$IPC::Unix::TRACE++;

{
	my $p = IPC::Unix->new( 'xt/readit' )->
	dup( '0>&-', '1+>/dev/null', '0>&1' )->
	dup( '2>|', my $pipe );
	$p->spawn();

	is <$pipe>, "read ok; 0 of 256 chars\n", "readit doesn't get EBADF";

	$p->close();
	$p->wait();
	is $p->{err}, 0, "readit exits with wstat 0";
}

{
	my $p = IPC::Unix->new( 'xt/readit' )->
	dup( '0>&-', '1+>/dev/null' )->
	dup( '2>|PIPE' );
	$p->spawn();

	is <PIPE>, "read error: Bad file descriptor\n", "readit gets EBADF";

	$p->close();
	$p->wait();
	is $p->{err}, 0, "readit exits with wstat 0";
}

done_testing;
