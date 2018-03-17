use strict;
use warnings;
use feature 'say';
use Log::ger;
use Log::ger::Output 'Screen';
use Log::ger::Util;
use DDP;

use File::JSON::Slurper qw( read_json );
use Mojo::SlackRTM;
use Mojo::IOLoop;
use DateTime;
use Lingua::Conjunction;
Lingua::Conjunction->penultimate(0);

our $VERSION = v0.0.1;

Log::ger::Util::set_level("trace");

log_debug 'reading config';
my $conf  = read_json('config.json');
my $token = $conf->{token};

my $slack = Mojo::SlackRTM->new( token => $token );

my %party_responses = ();
my $party_requestor = undef;

my ( $idle_handler, $party_handler, $timer_id );

$idle_handler = sub {
    my ( $slack, $event ) = @_;
    my $channel_id = $event->{channel};
    my $user_id    = $event->{user};
    my $user_name  = $slack->find_user_name($user_id);
    my $text       = $event->{text};

    log_trace 'got event "%s" in idle handler', $event;

    unless ( defined $text ) {
        log_debug 'skipping event type without text';
        return;
    }

    unless ( $channel_id =~ /^D/ ) {
        log_debug 'skipping non-DM';
        return;
    }

    unless ( grep { $user_name eq $_ } $conf->{users}->@* ) {
        log_debug 'skipping message from unwanted user';
        return;
    }

    unless ( $text =~ /\bcoffee\b/i ) {
        log_debug 'sending polite response to message I do not understand';
        $slack->send_message( $channel_id => "Sorry, I'm not sure what you meant. Try `I'd like to grab a coffee`" );
        return;
    }

    log_info 'got a request to form a party from %s on %s', $user_name;
    $slack->unsubscribe( message => $idle_handler );    # start listening for party responses
    $slack->on( message => $party_handler );

    %party_responses = ();
    $party_requestor = $user_name;

    my @other_candidates    = grep { $_ ne $party_requestor } $conf->{users}->@*;
    my @other_candidate_ids = map  { $slack->find_user_id($_) } @other_candidates;

    log_debug 'sending acknowledgement';
    $slack->send_message(
        $channel_id => sprintf 'Ok, I will ask %s for you',
        conjunction( map {"<\@$_>"} @other_candidate_ids )
    );

    my %dm_channels = get_dm_channels($slack);

    for (@other_candidates) {
        my $cand_id = $slack->find_user_id($_);

        log_debug 'sending request to %s', $_;

        $slack->send_message(
            $dm_channels{$cand_id} => sprintf '<@%s> would like to grab a coffee, are you in?',
            $user_id
        );

        $party_responses{$_} = undef;    # init a slot we will fill later
    }

    $timer_id = Mojo::IOLoop->timer(
        120 => sub {
            my @users_to_message = grep { $party_responses{$_} } keys %party_responses;
            push @users_to_message, $party_requestor;
            my @user_ids_to_message = map { $slack->find_user_id($_) } @users_to_message;

            my @users_to_timeout    = grep { !defined $party_responses{$_} } keys %party_responses;
            my @user_ids_to_timeout = map  { $slack->find_user_id($_) } @users_to_timeout;
            my $friendly_list = conjunction( map {"<\@$_>"} @user_ids_to_timeout );

            my %dm_channels = get_dm_channels($slack);

            for my $party_member (@users_to_message) {
                log_debug 'sending timeout summary to %s', $party_member;
                $slack->send_message(
                    $dm_channels{ $slack->find_user_id($party_member) } => "$friendly_list didn't respond" );
            }

            for my $user_to_timeout (@users_to_timeout) {
                log_debug 'timing out %s after two minutes', $user_to_timeout;
                $party_responses{$user_to_timeout} = 0;

                log_debug 'telling %s that they have timed out', $user_to_timeout;
                $slack->send_message( $dm_channels{ $slack->find_user_id($user_to_timeout) } =>
                        q{Sorry :sob:. You didn't respond in time} );
            }

            Mojo::IOLoop->remove($timer_id);    # remove myself
            $slack->unsubscribe( message => $party_handler );    # switch back to waiting for a party to form
            $slack->on( message => $idle_handler );

            # send confirmation message
            if ( @users_to_message == 1 ) {
                log_debug 'send consolation to requestor that they are on their own';
                $slack->send_message( $dm_channels{ $slack->find_user_id($party_requestor) } =>
                        q{Sorry :sob:. It looks like you're on your own for this one} );
            }
            else {
                log_debug 'send everyone on their way for coffee';

                pop @user_ids_to_message;                        # we no longer need to message the requestor

                my $friendly_list = conjunction( map {"<\@$_>"} @user_ids_to_message );
                $slack->send_message( $dm_channels{ $slack->find_user_id($party_requestor) } =>
                        "$friendly_list will be coming to your desk" );

                for my $user (@user_ids_to_message) {
                    $slack->send_message(
                        $dm_channels{$user} => sprintf q{Everyone is meeting at <@%s>'s desk},
                        $slack->find_user_id($party_requestor)
                    );
                }
            }
        }
    );
};

$party_handler = sub {
    my ( $slack, $event ) = @_;
    my $channel_id = $event->{channel};
    my $user_id    = $event->{user};
    my $user_name  = $slack->find_user_name($user_id);
    my $text       = $event->{text};

    log_trace 'got event "%s" in party handler', $event;

    unless ( defined $text ) {
        log_debug 'skipping event type without text';
        return;
    }

    unless ( $channel_id =~ /^D/ ) {
        log_debug 'skipping non-DM';
        return;
    }

    my @users_we_are_waiting_for = grep { !defined $party_responses{$_} } keys %party_responses;

    unless ( grep { $user_name eq $_ } @users_we_are_waiting_for ) {
        log_debug 'skipping message from unwanted user';
        return;
    }

    unless ( $text =~ /(\byes\b|\bno\b)/i ) {
        log_debug 'sending polite response to message I do not understand';
        $slack->send_message( $channel_id => "Sorry, I'm not sure what you meant. Try `yes` or `no`" );
        return;
    }

    my $response = lc $1;

    log_info 'got a response to a party request from %s', $user_name;
    $party_responses{$user_name} = $response =~ /\byes\b/i ? 1 : 0;

    log_debug 'sending acknowledgement';
    $slack->send_message( $channel_id => 'Thanks, I will let everyone know' );

    my @users_to_message = grep { $_ ne $user_name && ( !defined $party_responses{$_} || $party_responses{$_} ) }
        keys %party_responses;
    push @users_to_message, $party_requestor;

    my %dm_channels = get_dm_channels($slack);

    for (@users_to_message) {
        log_debug 'passing on response from %s to %s', $user_name, $_;
        $slack->send_message(
            $dm_channels{ $slack->find_user_id($_) } => sprintf '<@%s> is %s',
            $user_id, $party_responses{$user_name} ? 'in' : 'out'
        );
    }

    my $responses_remaining = grep { !defined $_ } values %party_responses;
    unless ($responses_remaining) {    # we're done here
        Mojo::IOLoop->remove($timer_id);    # switch back to waiting for a party to form
        $slack->unsubscribe( message => $party_handler );
        $slack->on( message => $idle_handler );

        my @users_to_message    = grep { $party_responses{$_} } keys %party_responses;
        my @user_ids_to_message = map  { $slack->find_user_id($_) } @users_to_message;

        # send confirmation message
        unless (@users_to_message) {
            log_debug 'send consolation to requestor that they are on their own';
            $slack->send_message( $dm_channels{ $slack->find_user_id($party_requestor) } =>
                    q{Sorry :sob:. It looks like you're on your own for this one} );
        }
        else {
            log_debug 'send everyone on their way for coffee';

            my $friendly_list = conjunction( map {"<\@$_>"} @user_ids_to_message );
            $slack->send_message( $dm_channels{ $slack->find_user_id($party_requestor) } =>
                    "$friendly_list will be coming to your desk" );

            for my $user (@user_ids_to_message) {
                $slack->send_message(
                    $dm_channels{$user} => sprintf q{Everyone is meeting at <@%s>'s desk},
                    $slack->find_user_id($party_requestor)
                );
            }
        }

    }
};

$slack->on( message => $idle_handler );    # begin by waiting for a party to form

# Mojo::IOLoop->recurring(
#     5 => sub {
#         say sprintf 'forming a party: %s', $forming_a_party ? 'true' : 'false';
#         p %party_responses;
#         my %chans = get_dm_channels($slack);
#         for ( keys %chans ) {
#             say $slack->find_user_name($_);
#         }
#     }
# );

$slack->start;

sub get_dm_channels {
    my $slack = shift;
    return map { $_->{user} => $_->{id} } $slack->metadata->{ims}->@*;
}
