#!/usr/bin/perl

# Keep it clean
use strict 'subs';
use warnings;

use threads;                            # NOTE We could probably have threading be
                                        # fully disabled if $processes == 0

# All modules are threadsafe and in the standard distribution
use Getopt::Long;
use Pod::Usage;
use File::Fetch;
use EPUB::Parser;
use WWW::Mechanize;
use URI::Escape;
use Thread::Queue;
use Thread::Semaphore;

# Setup options for modules
Getopt::Long::Configure (
    'auto_abbrev',                      # Allows truncation of options
    'gnu_compat'                        # Allows --opt=BLA syntax and --opt "BLA"
);
$File::Fetch::BLACKLIST = [qw|lwp|];    # Breaks the archive for an unknown reason

# Initialize EPUB parser
my $epub = EPUB::Parser->new;

# Initialize default values for configurable sections of the program
my $uid           = undef;              # Required (can't make base URL without it)
my $password      = undef;              # Required (can't make base URL without it)
my $file          = undef;              # Required (can't make base URL without it)
my $rating        = "Not Rated";        # Fic rating
my @warnings      = ();                 # Archive warnings
my @fandoms       = ("No Fandom");      # Fandom
my @categories    = ();                 # Categories
my @relationships = ();                 # Relationships
my @characters    = ();                 # Characters
my @additions     = ();                 # Additional tags
my @coauthors     = ();                 # Coauthor list
my $procs         = 1;                  # Number of worker threads
my $help          = 0;                  # Flag to print help and quit out

GetOptions (
    'uid=s'         => \$uid,
    'password=s'    => \$password,
    'processes:+'   => \$procs,
    'file=s'        => \$file,
    'rating=s'      => \$rating,
    'warnings=s@'   => \@warnings,
    'fandoms=s@'    => \@fandoms,
    'categories=s@' => \@categories,
    'characters=s@' => \@characters,
    'ships=s@'      => \@relationships,
    'freeforms=s@'  => \@additions,
    'help'          => \$help,
)
    and (
       $uid                             # $uid is mandatory
    && $password                        # $password is mandatory
    && $epub->load_file({ file_path =>  # $file is mandatory, load it
                          $file })
    && $processes > 0                   # Can't have less than one download thread
)
    or die pod2usage(                   # Print documentation and quit if bad opts
        -exitval => $help,              # With return value 0 if $help was not set
        -verbose => 2                   # Print all the sections
    );

# Threading initialization section
print "Starting download threads...";
my $mutex = Thread::Semaphore->new();   # When $mutex is up, then the thread has
STDOUT->autoflush();                    # exclusive STDOUT control
my $queue = Thread::Queue->new();       # Queue feeds URLs to download to workers
threads->create(\&worker)               # Create $procs download threads
    for 1 .. $procs;
print "Done!\r\n";

# Authenticate to the Archive
my $ao3 = WWW::Mechanize->new();
$ao3->get( 'http://archiveofourown.org/user_sessions/new' );
$ao3->submit_form(with_fields => { 'user_session[login]' => $uid, 'user_session[password]' => $password });

# Start a new work
$ao3->get( 'http://archiveofourown.org/works/new' );
$ao3->form_number(2);
$ao3->tick('work[warning_strings][]', $_) foreach @warnings;
$ao3->tick('work[category_strings][]', $_) foreach @categories;
$ao3->submit_form(with_fields => {
        'work[rating_string]'       => ($rating),
        'work[fandom_string]'       => join(',', @fandoms),
        'work[category_string]'     => join(',', @categories),
        'work[relationship_string]' => join(',', @relationships),
        'work[character_string]'    => join(',', @characters),
        'work[freeform_string]'     => join(',', @additions),
        'work[title]'               => substr($epub->odf->metadata->title, 0, 255),
        'pseud[byline]'             => join(',', @coauthors),
    });
$queue->end;

$_->join() foreach threads->list;
print 'Fetched ', $workCount, " works.\r\n";

sub worker {
    while (my $t = $queue->dequeue) {
        $mutex->down();
        print "Fetching ",@$t[0],"...";
        my $fetcher;
        my $tries = 0;
        do {
            $fetcher = File::Fetch->new(uri => @$t[1]);
            $fetcher->fetch(to => $directory);
            $tries++;
        } while ($tries < 30 && $fetcher->error());
        if ($tries == 30) {
            print "Failed to fetch @$t[1] :(\r\n";
        } else {
            print "Done!\r\n";
        }
        $mutex->up();
    }
}

__END__

=head1 NAME

AO3 EPUB Importer

=head1 SYNOPSIS

ao3-epub-importer -u UID -pa PASSWORD -f FILE [options]

=head1 OPTIONS

=over 12

=item B<-uid>

User ID on AO3. [required]

=item B<-password>

Password on AO3. [required]

=item B<-file>

EPUB to parse. [required]

=item B<-rating>

Default "Not Rated". Valid values are "General Audiences", "Teen And Up Audiences", "Mature", and "Explicit".

=item B<-processes>

Processes to run at once.

=back

=head1 DESCRIPTION

B<This program> will upload a properly structured EPUB file as an AO3 fic, attempting to make intelligent conversions of metadata where available.

=cut
