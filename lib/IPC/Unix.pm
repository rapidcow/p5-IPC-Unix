=head1 NAME

IPC::Unix - POSIX bidi popen, re-written

=head1 SYNOPSIS

   my $child = IPC::Unix->new(
      "git", "mktree"
   );
   $child->set(qw( hash-object -t tree ));
   $child->prog("git");
   $child->file("/usr/bin/git");
   $child->chdir( @dirs );

   $child->new->set(qw( version ));

   open my $null, '+>', '/dev/null';
   $child->dup( "<&-", "2>&1" );  # close or dup2
   $child->dup( ">", my $pipe );     # pipe+dup2
   $child->dup( \*STDERR, ">&", $null );  # dup2

   $child->env( %ENV );
   $child->setenv( TERM => 'dumb' );
   $child->unsetenv( qw(VISUAL EDITOR) );
   $child->resetenv( 'TERM' );

   $pid = $child->spawn;
   $child->close();
   waitpid($pid, 0);
   $child->ok();

=cut

package IPC::Unix;

our $VERSION = '0.0_001';
$VERSION = eval $VERSION;

use 5.006;
use strict;
use warnings;

use Carp qw(croak);
use Symbol ();

use File::Basename;

sub new {
	my $class = shift;
	my $self = do {
		if (ref $class) {
			bless {
				bin => $class->{bin},
				cmd => [ @{$class->{cmd}} ],
				env => [ @{$class->{env}} ],
			}, ref $class;
		} else {
			@_ or Carp::croak("${class}: new: no argument");
			bless { }, $class;
		}
	};

	if (@_) {
		$self->{bin} = $_[0];
		$self->{cmd} = [ basename($_[0]), @_[1 .. $#_] ];
	}
	$self;
}

# argv ("v" part of execvpe)
sub set {
	my $self = shift;
	my $argv = $self->{cmd};
	splice @$argv, 1, @$argv - 1, @_;
	$self;
}
sub prog {
	my $self = shift;
	my $argv = $self->{cmd};
	return $argv->[0] if !@_;
	$argv->[0] = $_[0]; $self;
}
sub file {
	my $self = shift;
	return $self->{bin} if !@_;
	$self->{bin} = $_[0]; $self;
}

sub chdir {
	my $self = shift;
	push @{$self->{dir}}, @_;
	$self;
}

# envp ("e" part of execvpe)
sub env {
	my $self = shift;
	return $self->{env} if !@_;
	$self->{env} = { @_ };
}
sub setenv {
	my $self = shift;
	my %setenv = @_;
	defined $self->{setenv} or $self->{setenv} = {};
	while (my ($K, $V) = each %setenv) {
		$self->{setenv}->{$K} = $V;
	}
	$self;
}
sub resetenv {
	my $self = shift;
	foreach my $K (@_) {
		delete $self->{setenv}->{$K};
	}
	$self;
}
sub unsetenv {
	my $self = shift;
	$self->setenv(map { $_ => undef } @_);
}

sub dup {
	my $self = $_[0];
	my $pkg = caller;
	for (my $o = 1; $o < @_; ++$o) {
		my ($fh0, $fh1, $mode);

		if (ref $_[$o] eq 'GLOB') {
			$fh0 = $_[$o++];
			$o < @_ or croak "dup: index $o: unexpected end after GLOB reference";
		} elsif (ref \$_[$o] eq 'GLOB') {
			$fh0 = \$_[$o++];
			$o < @_ or croak "dup: index $o: unexpected end after GLOB scalar";
		} else {
			pos($_[$o]) = 0;
			if ($_[$o] =~ /\G([0-9]+)/gc) {
				$1 > 2 and croak "dup: index $o: don't know how to map file descriptor: $1";
				$fh0 = \(*STDIN, *STDOUT, *STDERR)[$1];
			} elsif ($_[$o] =~ /\G([^<>]+)/gc) {
				$fh0 = Symbol::qualify_to_ref($1, $pkg);
				++$o;
				$o < @_ or croak "dup: index $o: unexpected end after file descriptor";
			} elsif ($_[$o] =~ /^>/)
				{ $fh0 = \*STDOUT; }
			elsif ($_[$o] =~ /^</)
				{ $fh0 = \*STDIN; }
			else {
				croak "dup: index $o: expecting source file";
			}
			if ($_[$o] =~ /\G\z/gc) {
				++$o;
				$o < @_ or croak "dup: index $o: unexpected end after file descriptor";
			}
		}

		unless ($_[$o] =~ /(<&-?|>&-?|<|>)/gc) {
			croak "dup: index $o: cannot find a valid file mode in: $_[$o]";
		} else {
			$mode = $1;
			if ($mode eq '<&-' || $mode eq '>&-') {
				push @{$self->{dup}}, [ $fh0, $mode ];
				next;
			} elsif ($_[$o] =~ /\G\z/gc) {
				++$o;
				$o < @_ or croak "dup: index $o: unexpected end after file mode";
			}
		}

		# Handle < or >
		if ($mode eq '<' || $mode eq '>') {
			if ($mode eq '<') {
				pipe $fh1, $_[$o] or croak "dup: index $o: pipe `<': $!";
			} else {
				pipe $_[$o], $fh1 or croak "dup: index $o: pipe `>': $!";
			}
			push @{$self->{dup}}, [ $fh0, $mode, $fh1 ];
			push @{$self->{fds}}, $_[$o];
			next;
		}

		if (ref $_[$o] eq 'GLOB') {
			$fh1 = $_[$o];
		} elsif (ref \$_[$o] eq 'GLOB') {
			$fh1 = \$_[$o];
		} elsif (defined $_[$o]) {
			if ($_[$o] =~ /\G([0-9]+)/gc) {
				$1 > 2 and croak "dup: index $o: don't know how to map file descriptor: $1";
				$fh1 = \(*STDIN, *STDOUT, *STDERR)[$1];
			} elsif ($_[$o] =~ /\G(.+)/gc) {
				Symbol::qualify_to_ref($1, $_);
			} else {
				croak "dup: index $o: unexpected end while expecting destination file";
			}
		}

		if (defined $fh1) {
			push @{$self->{dup}}, [ $fh0, $mode, $fh1 ];
			next;
		} else {
			# Weird way to write ">&-" or "<&-" :/
			push @{$self->{dup}}, [ $fh0, "$mode-" ];
		}
	}
	$self;
}

sub spawn {


}
sub wait { }
sub ok { }

1; # make require happy
