use strict;
use warnings;
use feature 'say';
use DDP;

use File::JSON::Slurper qw( read_json );
use Mojo::SlackRTM;
use DateTime;

our $VERSION = v0.0.1;

my $conf = read_json('config.json');
my $token = $conf->{token};
my @users_with_limits = keys $conf->{coffees_per_day}->%*;
 
my $slack = Mojo::SlackRTM->new(token => $token);

my $today = DateTime->today;
my $coffees_today = 0;
my %previews_sent_to;

$slack->on(message => sub {
  my ($slack, $event) = @_;
  my $channel_id = $event->{channel};
  my $user_id    = $event->{user};
  my $user_name  = $slack->find_user_name($user_id);
  my $text       = $event->{text};

  return unless defined $text; # nothing do do if its not an event with text!

  # send people away with a preview message if they DM
  if ($channel_id =~ /^D/) {
    my $preview_number = ++$previews_sent_to{$user_id};

    return if $preview_number >= 3; # ignore them if they're harassing us

    if ($preview_number == 2) { # let them know a girl needs some space from time to time!
        $slack->send_message($channel_id => "I've already asked you nicely not to message yet :smile:");
        $slack->send_message($channel_id => "I'll let you know when I'm ready for your attention :wink:");

        return;
    }

    # respond to pleasantries and salutations in kind
    if (
      $text =~ /(\bhey\b|\bhi\b|\bhello\b|\b(?:good\b?)?(morning|afternoon|evening)\b|\bafternoon\b|\bwhat'?s\bup\b?|\bwass?up\b)/i
      || $text =~ /\b(.*)\bkaffina\b/i
    ) {
        my $formatted = ucfirst $1 =~ s/^\s+|\s+$//gr; # trim whitespace and capitalise
        $slack->send_message($channel_id => "$formatted yourself :grinning:");
    }

    # Explain our perks
    $slack->send_message($channel_id => "Please don't chat with me right now since I'm not ready just yet! :blush:");
    $slack->send_message($channel_id => "Soon I'll be able to help you organise coffee breaks :coffee:");
    $slack->send_message($channel_id => "Without distracting your colleagues who are busy working hard :computer:");
    $slack->send_message($channel_id => "Or have just had too much caffeine today :grinning_face_with_one_large_and_one_small_eye:");
    $slack->send_message($channel_id => "And of course I'll be helping you out if you're ever in one of those situations yourself! :helmet_with_white_cross:");
    $slack->send_message($channel_id => "So everyone gets the frictionless coffee experience they deserve :kissing_heart:");

    return;
  }

  # skip anything non #coffee
  my $coffee_chan_id = $slack->find_channel_id('coffee')
    or die 'cannot get ID for coffee channel';
  return unless $channel_id eq $coffee_chan_id;

  # ignore things that aren't the coffee request
  return unless $text =~ /\bc[oa]ff?e?e?\b|\bping\b/i;

  # check if we're reached tomorrow yet
  unless ($today == DateTime->today) { 
      say 'resetting limits';
      $today = DateTime->today;
      $coffees_today = 0;
  }
  
  $coffees_today++;
  my @users_beyond_limit = grep { $coffees_today > $conf->{coffees_per_day}->{$_} } @users_with_limits; 

  return unless @users_beyond_limit;

  my $list_of_users =
    join ' and ', 
    map { "<\@$_>" } 
    map { $slack->find_user_id($_) or die "cannot get ID for $_ user" } @users_beyond_limit;

  $slack->send_message($channel_id => "No more coffes for $list_of_users but thanks for asking :smile:");
});

$slack->start;