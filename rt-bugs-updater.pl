#!/usr/bin/env perl

use Modern::Perl;

use Try::Tiny;
use RT::Client::REST;
use BZ::Client::REST;
use Term::ANSIColor;
use Data::Dumper;
use Getopt::Long::Descriptive;
use Carp::Always;

my ( $opt, $usage ) = describe_options(
    'tracker-updater.pl',
    [ "rt-url=s",      "BWS RT URL",      { required => 1, default => $ENV{RT_URL} } ],
    [ "rt-username=s", "BWS RT username", { required => 1, default => $ENV{RT_USER} } ],
    [ "rt-password=s", "BWS RT password", { required => 1, default => $ENV{RT_PW} } ],
    [],
    [ "community-url=s",      "Community tracker URL",      { required => 1, default => $ENV{KOHA_URL} } ],
    [ "community-username=s", "Community tracker username", { required => 1, default => $ENV{KOHA_USER} } ],
    [ "community-password=s", "Community tracker password", { required => 1, default => $ENV{KOHA_PW} } ],
    [],
    [ 'verbose|v+', "Print extra stuff" ],
    [ 'help|h', "Print usage message and exit", { shortcircuit => 1 } ],
);

print( $usage->text ), exit if $opt->help;

my $verbose = $opt->verbose || 0;

my $rt_url  = $opt->rt_url;
my $rt_user = $opt->rt_username;
my $rt_pass = $opt->rt_password;

my $bz_koha_url  = $opt->community_url;
my $bz_koha_user = $opt->community_username;
my $bz_koha_pass = $opt->community_password;

my $koha_client = BZ::Client::REST->new(
    {
        user     => $bz_koha_user,
        password => $bz_koha_pass,
        url      => $bz_koha_url,
    }
);

my $rt = RT::Client::REST->new(
    server  => $rt_url,
    timeout => 30,
);
try {
    $rt->login( username => $rt_user, password => $rt_pass );
}
catch {
    die "Problem logging in: ", shift->message;
};


# Create tracks
say colored( 'Finding bug tickets', 'green' ) if $verbose;
my $rt_query = q{ Status = '__Active__' AND ( Queue = 'Bugs' OR Queue = 'Support' ) };
my @ids = $rt->search(
    type    => 'ticket',
    query   => $rt_query,
    orderby => '-id',
);

my @tickets;

foreach my $ticket_id (@ids) {
    sleep(1);    # pause for 1 second between requests so we don't kill RT
    my $ticket = $rt->show( type => 'ticket', id => $ticket_id );

    say "Working on ticket " . colored( $ticket_id, 'cyan' ) if $verbose > 1;
    my ($bug_id, $others) = split(',', $ticket->{'CF.{Community Bug}'} );

    $bug_id ||= q{};
    $others ||= q{};

    $bug_id =~ s/^\s+|\s+$//g;
    $others =~ s/^\s+|\s+$//g;

    say "Found multiple bugs, using bug " . colored( $bug_id, 'green' ) . ", skipping " . colored( $others, 'green' ) if $others && $verbose;

    unless ($bug_id) {
        say colored( "Bug not found for ticket $ticket_id", 'red' )
          if $verbose;
        next;
    }
    sleep(4);    # Pause for another 4 seconds so we don't get banned from bugzilla
    say "Found related bug " . colored( $bug_id, 'green' );

    my $bug = $koha_client->get_bug($bug_id);

    my $ticket_status = $ticket->{'CF.{Bug Workflow}'} || q{};
    my $ticket_version = $ticket->{'CF.{Koha Version}'} || q{};

    my $bug_status = $bug->{status} || q{};
    my $bug_version = $bug->{cf_release_version} || q{};

    if ( $ticket_status ne $bug_status || $ticket_version ne $bug_version ) {
	say "RT ticket status " . colored( $ticket_status, 'cyan' ) . " doesn't match community bug status " . colored( $bug_status, 'green' ) . ", updating RT ticket." if $verbose > 1;
        $rt->edit(
            type => 'ticket',
            id   => $ticket_id,
            set  => {
                "CF.{Bug Workflow}" => $bug_status,
                "CF.{Koha Version}" => $bug_version,
            }
        );
    } else {
        say "Community bug and RT ticket status match: " . colored( $bug_status, 'yellow' ) . ", skipping update." if $verbose > 1;
    }
}

say colored( 'Finished!', 'green' ) if $verbose;
