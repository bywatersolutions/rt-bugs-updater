#!/usr/bin/env perl

use Modern::Perl;

use BZ::Client::REST;
use Carp::Always;
use Data::Dumper;
use Getopt::Long::Descriptive;
use LWP::UserAgent;
use RT::Client::REST;
use Term::ANSIColor;
use Try::Tiny;
use JSON qw(to_json);

my ( $opt, $usage ) = describe_options(
    'tracker-updater.pl',
    [ "rt-url=s", "BWS RT URL", { required => 1, default => $ENV{RT_URL} } ],
    [
        "rt-username=s",
        "BWS RT username",
        { required => 1, default => $ENV{RT_USER} }
    ],
    [
        "rt-password=s",
        "BWS RT password",
        { required => 1, default => $ENV{RT_PW} }
    ],
    [],
    [
        "community-url=s",
        "Community tracker URL",
        { required => 1, default => $ENV{KOHA_URL} }
    ],
    [
        "community-username=s",
        "Community tracker username",
        { required => 1, default => $ENV{KOHA_USER} }
    ],
    [
        "community-password=s",
        "Community tracker password",
        { required => 1, default => $ENV{KOHA_PW} }
    ],
    [],
    [
        'slack|s=s',
        "Slack webhook URL",
        { required => 1, default => $ENV{SLACK_URL} }
    ],
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

my $ua = LWP::UserAgent->new;
$ua->post(
    $opt->slack,
    Content_Type => 'application/json',
    Content      => to_json( { text => "Running RT Bugs Updater!" } ),
) if $opt->slack;

my @queues = ( 'Bugs', 'Support', 'Development' );
foreach my $q (@queues) {

    # Create tracks
    say colored( "Finding '$q' tickets", 'green' ) if $verbose;

    my $rt_query = qq{ Status = '__Active__' AND Queue = '$q' };
    my @ids      = $rt->search(
        type    => 'ticket',
        query   => $rt_query,
        orderby => '-id',
    );

    my @tickets;

    foreach my $ticket_id (@ids) {
        sleep(1);    # pause between requests so we don't kill RT
        my $ticket = $rt->show( type => 'ticket', id => $ticket_id );

        say "Working on ticket " . colored( $ticket_id, 'cyan' )
          if $verbose > 1;
        my ( $bug_id, $others ) = split( ',', $ticket->{'CF.{Community Bug}'} );

        $bug_id ||= q{};
        $others ||= q{};

        $bug_id =~ s/^\s+|\s+$//g;
        $others =~ s/^\s+|\s+$//g;

        say "Found multiple bugs, using bug "
          . colored( $bug_id, 'green' )
          . ", skipping "
          . colored( $others, 'green' )
          if $others && $verbose;

        unless ($bug_id) {
            say colored( "Bug not found for ticket $ticket_id", 'red' )
              if $verbose;

            next;
        }

        # Pause for another 1 second so we don't get banned from bugzilla
        sleep(1);

        say "Found related bug " . colored( $bug_id, 'green' );

        try {
            my $bug = $koha_client->get_bug($bug_id);

            my $ticket_status  = $ticket->{'CF.{Bug Workflow}'} || q{};
            my $ticket_version = $ticket->{'CF.{Koha Version}'} || q{};

            my $bug_status  = $bug->{status}             || q{};
            my $bug_version = $bug->{cf_release_version} || q{};

            # Trim leading and trailing whitespace
            $ticket_status  =~ s/^\s+|\s+$//g;
            $ticket_version =~ s/^\s+|\s+$//g;

            # Remove all whitespace from bug version to match RT version: '20.05.00, 19.11.03' => '20.05.00,19.11.03'
            $bug_version    =~ s/\s+|\s+//g;

            if (   lc($ticket_status) ne lc($bug_status)
                || lc($ticket_version) ne lc($bug_version) )
            {
                say "RT ticket status '"
                  . colored( $ticket_status, 'cyan' )
                  . "' doesn't match community bug status '"
                  . colored( $bug_status, 'green' )
                  . "', updating RT ticket."
                  if $verbose > 1 && lc($ticket_status) ne lc($bug_status);

                say "RT ticket version '"
                  . colored( $ticket_version, 'cyan' )
                  . "' doesn't match community bug version '"
                  . colored( $bug_version, 'green' )
                  . "', updating RT ticket."
                  if $verbose > 1 && lc($ticket_version) ne lc($bug_version);

                send_slack_bug_update(
                    {
                        bug            => $bug,
                        bug_status     => $bug_status,
                        bug_version    => $bug_version,
                        bz_koha_url    => $bz_koha_url,
                        rt_url         => $rt_url,
                        ticket         => $ticket,
                        ticket_id      => $ticket_id,
                        ticket_status  => $ticket_status,
                        ticket_version => $ticket_version,
                        ua             => $ua,
                    }
                );

                $rt->edit(
                    type => 'ticket',
                    id   => $ticket_id,
                    set  => {
                        "CF.{Bug Workflow}" => $bug_status,
                        "CF.{Koha Version}" => $bug_version,
                    }
                );
            }
            else {
                say "Community bug and RT ticket fields match: "
                  . colored( $bug_status, 'yellow' )
                  . " / "
                  . colored ( $bug_version, 'yellow' )
                  . ", skipping update."
                  if $verbose > 1;
            }
        };
    }
}

$ua->post(
    $opt->slack,
    Content_Type => 'application/json',
    Content => to_json( { text => "RT Bugs Updater has finished running!" } ),
) if $opt->slack;

say colored( 'Finished!', 'green' ) if $verbose;

sub send_slack_bug_update {
    my ($params) = @_;

    my $bug            = $params->{bug};
    my $bug_status     = $params->{bug_status};
    my $bz_koha_url    = $params->{bz_koha_url};
    my $rt_url         = $params->{rt_url};
    my $ticket         = $params->{ticket};
    my $ticket_id      = $params->{ticket_id};
    my $ticket_status  = $params->{ticket_status};
    my $ticket_version = $params->{ticket_version};
    my $bug_version    = $params->{bug_version};
    my $ua             = $params->{ua};

    my @fields;
    if ( lc($ticket_status) ne lc($bug_status) ) {
        push(
            @fields,
            (
                {
                    title => "From Status",
                    value => $ticket_status,
                    short => JSON::true,
                },
                {
                    title => "To Status",
                    value => $bug_status,
                    short => JSON::true,
                }
            )
        );
    }

    if ( lc($ticket_version) ne lc($bug_version) ) {
        push(
            @fields,
            (
                {
                    title => "From Version",
                    value => $ticket_version,
                    short => JSON::true,
                },
                {
                    title => "To Version",
                    value => $bug_version,
                    short => JSON::true,
                }
            )
        );
    }

    my $json_data = {
        "attachments" => [
            {
                #pretext => "Pretext _supports_ mrkdwn",
                title => "Updated <$rt_url/Ticket/Display.html?id=$ticket_id|Ticket $ticket_id: $ticket->{Subject}>",
                text => "<$bz_koha_url/show_bug.cgi?id=$bug->{id}|Boog $bug->{id}: $bug->{summary}>",
                fields => \@fields,
                mrkdwn_in => [ "text", "pretext", "fields" ],
            }
        ]
    };
    my $json_text = to_json($json_data);

    $ua->post(
        $opt->slack,
        Content_Type => 'application/json',
        Content      => $json_text,
    ) if $opt->slack;
}
