package Log::Procmail;

require 5.005;
use strict;
use IO::File;
use Carp;

use vars qw/ $VERSION /;
local $^W = 1;

$VERSION = '0.07';

my %month;
@month{qw/ Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec /} = ( 0 .. 11 );

my $DATE = qr/(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ([ \d]\d) (\d\d):(\d\d):(\d\d) .*(\d\d\d\d)/;

=head1 NAME

Log::Procmail - Perl extension for reading procmail logfiles.

=head1 SYNOPSIS

 use Log::Procmail;

 my $log = new Log::Procmail 'procmail.log';

 # loop on every abstract
 while(my $rec = $log->next) {
     # do something with $rec->folder, $rec->size, etc.
 }

=head1 DESCRIPTION

=head2 Log::Procmail

Log::Procmail reads procmail(1) logfiles and returns the abstracts one by one.

=over 4

=item $log = Log::Procmail->new( @files );

Constructor for the procmail log reader.  Returns a reference to a
Log::Procmail object.

The constructor accepts a list of file as parameter. This allows you to
read records from several files in a row:

 $log = Log::Procmail->new( "$ENV{HOME}/.procmail/log.2",
                            "$ENV{HOME}/.procmail/log.1",
                            "$ENV{HOME}/.procmail/log", );

When $log reaches the end of the file "log", it doesn't close the file.
So, after B<procmail> processes some incoming mail, the next call to next()
will return the new records.

=cut

sub new {
    my $class = shift;
    return bless {
        fh     => new IO::File,
        files  => [@_],
        errors => 0,
        buffer => [],
    }, $class;
}

=item $rec = $log->next

Return a Log::Procmail::Abstract object that represent an entry in the log
file. Return undef if there is no record left in the file.

When the Log::Procmail object reaches the end of a file, and this file is
not the last of the stack, it closes the current file and opens the next
one.

When it reaches the end of the last file, the file is not closed. Next
time the record method is called, it will check again in case new abstracts
were appended.

Procmail(1) log look like the following:

 From karen644552@btinternet.com  Fri Feb  8 20:37:24 2002
  Subject: Stock Market Volatility Beating You Up? (18@2)
   Folder: /var/spool/mail/book						   2840

Some informational messages can be put by procmail(1) in the log file.
If the C<errors> attribute is true, these lines are returned one at a time.

With errors enabled, you have to check that next() actually returns a
Log::Procmail::Abstract object. Here is an example:

    $log->errors(1);

    # fetch data
    while ( $rec = $log->next ) {

        # if it's an error line
        if ( !ref $rec ) {
            # this is not a log, but an informational message
            # do something with it
            next;
        }

        # normal log processing
    }

=cut

sub next {
    my $log = shift;    # who needs $self?

    # open the file if necessary
    unless ( $log->{fh}->opened ) {
        if ( @{ $log->{files} } ) {
            my $file = shift @{ $log->{files} };
            $log->_open($file);
        }
        else { return }
    }

    # try to read a record (3 lines)
    my $fh  = $log->{fh};
  READ:
    {
        my $read;
        while (<$fh>) {
            $read++;

            # should carp if doesn't get what's expected
            # (From, then Subject, then Folder)

            # From create a new Abstract
            /^From (.+?) +($DATE)$/o && do {
                push @{$log->{buffer}}, Log::Procmail::Abstract->new;

                # assert: $read == 1;
                $log->{buffer}[-1]->from($1);
                $log->{buffer}[-1]->date($2);

                # return ASAP
                last READ if @{$log->{buffer}} > 1;
                next;
            };

            # assert: $read == 2;
            /^ Subject: (.*)/i && do {
                push @{$log->{buffer}}, Log::Procmail::Abstract->new
                    unless @{$log->{buffer}};
                $log->{buffer}[0]->subject($1);
                next;
            };

            # procmail tabulates with tabs and spaces... :-(
            # assert: $read == 3;
            # Folder means the end of this record
            /^  Folder: (.*?)\s+(\d+)$/ && do {
                push @{$log->{buffer}}, Log::Procmail::Abstract->new
                  unless @{$log->{buffer}};

                # assert: $read == 3;
                $log->{buffer}[0]->folder($1);
                $log->{buffer}[0]->size($2);
                last READ;
            };

            # fall through: some error message
            # shall we ignore it?
            next unless $log->{errors};

            # or return it?
            chomp;
            push @{$log->{buffer}}, $_;
            last;
        }

        # in case we couldn't read the first line
        if ( !$read or @{$log->{buffer}} == 0 ) {

            # return ASAP
            last READ if @{$log->{buffer}};

            # go to next file
            if ( @{ $log->{files} } ) {
                $fh->close;
                my $file = shift @{ $log->{files} };
                $log->_open($file);
                redo READ;
            }

            # unless it's the last one
            else { return }
        }
    }

    # we have an abstract
    my $rec = shift @{$log->{buffer}};
    if($rec->isa( 'Log::Procmail::Abstract')) {
        # the folder field is required
        goto READ unless defined $rec->folder;
        $rec->{source} = $log->{source};
    }

    return $rec
}

=item $log->push( $file [, $file2 ...] );

Push one or more files on top of the list of log files to examine.
When Log::Procmail runs out of abstracts to return (i.e. it reaches the
end of the file), it transparently opens the next file (if there is one)
and keeps returning new abstracts.

=cut

sub push {
    my $log = shift;
    push @{ $log->{files} }, @_;
}

=item $log->errors( [bool] );

Set or get the error flag. If set, when the next() method will return
the string found in the log file, instead of ignoring it. Be careful:
it is a simple string, not a Log::Procmail::Abstract object.

Default is to return no error.

=cut

sub errors {
    my $self = shift;
    @_ ? $self->{errors} = shift: $self->{errors};
}

# *internal method*
# opens a file or replace the old filehandle by the new one
# push() can therefore accept refs to typeglobs, IO::Handle, or filenames
sub _open {
    my ( $log, $file ) = @_;
    if ( ref $file eq 'GLOB' ) {
        $log->{fh} = *$file{IO};
        carp "Closed filehandle $log->{fh}" unless $log->{fh}->opened;
    }
    elsif ( ref $file && $file->isa('IO::Handle') ) {
        $log->{fh} = $file;
    }
    else {
        $log->{fh}->open($file) or carp "Can't open $file: $!";
    }
    $log->{source} = $file;
}

sub DESTROY {
    my $self = shift;
    if ( $self->{fh} && $self->{fh}->opened ) { $self->{fh}->close }
}

=back

=head2 Log::Procmail::Abstract

Log::Procmail::Abstract is a class that hold the abstract information.
Since the abstract hold From, Date, Subject, Folder and Size information,
all this can be accessed and modified through the from(), date(), subject(),
folder() and size() methods.

Log::Procmail::next() returns a Log::Procmail::Abstract object.

=cut

package Log::Procmail::Abstract;

use Carp;

sub new {
    my $class = shift;
    return bless {@_}, $class;
}

=over 4

=item Log::Procmail::Abstract accessors

The Log::Procmail::Abstract object accessors are named from(), date(),
subject(), folder() and size(). They return the relevant information
when called without argument, and set it to their first argument
otherwise.

    # count mail received per folder
    while( $rec = $log->next ) { $folder{ $rec->folder }++ }

The source() accessor returns the name of the log file or the string
representation of the handle, if a filehandle was given.

=cut

for my $attr (qw( from date subject size folder source ) ) {
    no strict 'refs';
    *{"Log::Procmail::Abstract::$attr"} = sub {
        my $self = shift;
        @_ ? $self->{$attr} = shift: $self->{$attr};
    }
}

=item $rec->ymd()

Return the date in the form C<yyyymmmddhhmmss> where each field is what
you think it is. C<;-)> This method is read-only.

=cut

sub ymd {
    my $self = shift;
    croak("Log::Procmail::Abstract::ymd cannot be used to set the date")
      if @_;
    return undef unless defined $self->{date};
    $self->{date} =~ /^$DATE$/o;
    return undef unless $1;
    return sprintf( "%04d%02d%02d$3$4$5", $6, $month{$1} + 1, $2 );
}

=back

=head1 TODO

The Log::Procmail object should be able to read from STDIN.

=head1 BUGS

Sometimes procmail(1) logs are mixed up. When this happens, I've chosen
to accept them the way mailstat(1) does: they are discarded unless they
have a C<Folder> line.

Please report all bugs through the rt.cpan.org interface:

http://rt.cpan.org/NoAuth/Bugs.html?Dist=Log-Procmail

=head1 AUTHOR

Philippe "BooK" Bruhat <book@cpan.org>.

Thanks to Briac "Oeufmayo" Pilpr� and David "Sniper" Rigaudiere for early
comments on irc. Thanks to Olivier "rs" Poitrey for giving me his huge
procmail log file (51 Mb spanning over a two-year period) and for probably
being the only user of this module. Many thanks to Michael Schwern for
insisting so much on the importance of tests and documentation.

Many thanks to "Les Mongueurs de Perl" for making cvs.mongueurs.net
available for Log::Procmail and many other projects.

=head1 COPYRIGHT 

Copyright (c) 2002-2004, Philippe Bruhat. All Rights Reserved.

=head1 LICENSE

This module is free software. It may be used, redistributed
and/or modified under the terms of the Perl Artistic License
(see http://www.perl.com/perl/misc/Artistic.html)

=head1 SEE ALSO

perl(1), procmail(1).

=cut

1;
