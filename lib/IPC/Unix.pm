=head1 NAME

IPC::Unix - Unix-only bidi popen, re-written

=cut

package IPC::Unix;

use 5.006;
use strict;
use warnings;

=head1 DESCRIPTION

=over

=item IPC::Unix->B<run>( PROG, ARGV )



   [ ARGV0??? ]

Redirection:

   [ '1>&-'         ]    # close STDOUT
   [ '2>&1'         ]    # STDERR, &>STDOUT
   [ '2>/dev/null'  ]    # open and dup2(2)
   [ '<', \'hello!' ]    # open scalar similarly
              # (not sure if that works though)

=cut

sub run {
	my ($indv, $envp);

	foreach my $arg (@_) {
		if (ref $arg eq 'ARRAY') {
			
		}
	}
}

=back

=cut

1; # make require happy
