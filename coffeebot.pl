use strict;
use warnings;
use feature 'say';
use Log::ger;
use Log::ger::Output 'Screen';
use Log::ger::Util;
use DDP;

use File::JSON::Slurper qw( read_json );
use DBM::Deep;
use Mojo::SlackRTM;
use DateTime;

our $VERSION = v0.0.1;

Log::ger::Util::set_level("trace");

log_debug 'reading config';
my $conf              = read_json('config.json');
my $token             = $conf->{token};
my @users_with_limits = keys $conf->{coffees_per_day}->%*;

my $slack = Mojo::SlackRTM->new( token => $token );

log_debug 'opening state database';
tie my %state, 'DBM::Deep', 'state.db';

log_trace 'previous state is "%s"', \%state;

$state{today}            //= DateTime->today;    # we have to store this too so we know what day the coffees state is from
$state{coffees_today}    //= 0;
$state{previews_sent_to} //= {};

$slack->on(
    message => sub {
        my ( $slack, $event ) = @_;
        my $channel_id = $event->{channel};
        my $user_id    = $event->{user};
        my $user_name  = $slack->find_user_name($user_id);
        my $text       = $event->{text};

        log_trace 'got event "%s"', $event;

        unless ( defined $text ) {
            log_debug 'skipping event type without text';
            return;
        }

        # send people away with a preview message if they DM
        if ( $channel_id =~ /^D/ ) {
            my $preview_number = ++$state{previews_sent_to}{$user_id};

            log_info 'got a DM from ID %s, this is number %d from this user', $user_id, $preview_number;

            if ( $preview_number >= 3 ) {
                log_info 'ignoring it as they are harassing us';
                return;
            }

            if ( $preview_number == 2 ) {    # let them know a girl needs some space from time to time!
                log_info 'sending them a firm message not to message again';
                $slack->send_message( $channel_id => "I've already asked you nicely not to message yet :smile:" );
                $slack->send_message( $channel_id => "I'll let you know when I'm ready for your attention :wink:" );

                return;
            }

            # respond to pleasantries and salutations in kind
            if (   $text =~ /(\bhey\b|\bhi\b|\bhello\b|\b(?:good\b?)?(morning|afternoon|evening)\b|\bafternoon\b|\bwhat'?s\bup\b?|\bwass?up\b)/i
                || $text =~ /\b(.*)\bkaffina\b/i )
            {
                log_info 'they are being polite with "%s" so responding in kind', $1;
                my $formatted = ucfirst $1 =~ s/^\s+|\s+$//gr;    # trim whitespace and capitalise
                $slack->send_message( $channel_id => "$formatted yourself :grinning:" );
            }

            log_info 'sending them the preview text';
            $slack->send_message( $channel_id => "Please don't chat with me right now since I'm not ready just yet! :blush:" );
            $slack->send_message( $channel_id => "Soon I'll be able to help you organise coffee breaks :coffee:" );
            $slack->send_message( $channel_id => "Without distracting your colleagues who are busy working hard :computer:" );
            $slack->send_message( $channel_id => "Or have just had too much caffeine today :grinning_face_with_one_large_and_one_small_eye:" );
            $slack->send_message( $channel_id =>
                    "And of course I'll be helping you out if you're ever in one of those situations yourself! :helmet_with_white_cross:" );
            $slack->send_message( $channel_id => "So everyone gets the frictionless coffee experience they deserve :kissing_heart:" );

            return;
        }

        # skip anything non #coffee
        my $coffee_chan_id = $slack->find_channel_id('coffee')
            or die 'cannot get ID for coffee channel';
        unless ( $channel_id eq $coffee_chan_id ) {
            log_debug 'skipping message because it is not in the coffee channel';
            return;
        }

        # ignore things that aren't the coffee request
        unless ( $text =~ /\bc[oa]ff?e?e?\b|\bping\b/i ) {
            log_debug 'skipping message because it is not a request for coffee';
            return;
        }

        # check if we're reached tomorrow yet
        unless ( $state{today} == DateTime->today ) {
            log_info 'resetting limits since it is now the next day';
            $state{today}         = DateTime->today;
            $state{coffees_today} = 0;
        }

        $state{coffees_today}++;
        my @users_beyond_limit = grep { $state{coffees_today} > $conf->{coffees_per_day}->{$_} } @users_with_limits;

        unless (@users_beyond_limit) {
            log_debug 'no users are beyond their limits so nothing to do';
            return;
        }

        my $list_of_users = join ' and ', map {"<\@$_>"}
            map { $slack->find_user_id($_) or die "cannot get ID for $_ user" } @users_beyond_limit;

        log_info 'sending automatic polite decline message';
        $slack->send_message( $channel_id => "No more coffes for $list_of_users but thanks for asking :smile:" );
    }
);

$slack->start;
