package D2TG::Config::Flags;

use strict;
use warnings;
use D2TG::Config;

# TGT-267: shift_flag_value/extract_db_flag/extract_db_flag_or_die/
# bot_groups were an organizational mismatch in D2TG::Config.pm - CLI
# flag-parsing is a distinct concern from that module's own
# env-reading/version/error-classification concerns. Extracted here,
# mirroring D2TG::Reply::Args/D2TG::Config::Paths's own precedent.
# Full documentation lives in D2TG/Config/Flags.pod (REQ-028: POD in a
# separate file).
sub shift_flag_value {
    my ( $args, $flag_label ) = @_;

    my $value = shift @$args;
    die "$flag_label requires a value\n"
      unless defined $value && $value ne '' && $value !~ /^--?[A-Za-z]/;

    return $value;
}

sub extract_db_flag {
    my (@args) = @_;

    my $alias;
    my @rest;
    while (@args) {
        my $arg = shift @args;
        if ( $arg eq '--db' || $arg eq '-d' ) {
            $alias = shift_flag_value( \@args, '--db/-d' );
        }
        else {
            push @rest, $arg;
        }
    }

    return ( $alias, @rest );
}

sub extract_db_flag_or_die {
    my (@args) = @_;

    my @result = eval { extract_db_flag(@args) };
    if ($@) {
        print STDERR $@;
        exit 1;
    }
    return @result;
}

sub bot_groups {
    my (%args) = @_;

    my @argv = @{ $args{argv} || [] };
    my $env_chat_id = exists $args{env_chat_id} ? $args{env_chat_id} : $ENV{D2TG_CHAT_ID};
    my $env_token   = exists $args{env_token}   ? $args{env_token}   : $ENV{D2TG_TOKEN};

    push @argv, '--chat_id', $env_chat_id if defined $env_chat_id && length $env_chat_id;
    push @argv, '--bot',     $env_token   if defined $env_token   && length $env_token;

    my @groups;
    my $current;
    my @rest;

    while (@argv) {
        my $arg = shift @argv;

        if ( $arg eq '--chat_id' ) {
            my $value = shift_flag_value( \@argv, '--chat_id' );

            die "D2TG::Config::Flags::bot_groups: --chat_id value '$value' is not "
              . "Telegram's canonical numeric chat-id shape (bare digits, "
              . "or a leading '-' for a group/supergroup/channel)\n"
              unless $value =~ /^-?\d+$/;

            $current = { chat_id => $value, bots => [] };
            push @groups, $current;
        }
        elsif ( $arg eq '--bot' ) {
            die "D2TG::Config::Flags::bot_groups: --bot given before any --chat_id\n"
              unless $current;
            my $token = shift_flag_value( \@argv, '--bot' );
            push @{ $current->{bots} }, $token;
        }
        else {
            push @rest, $arg;
        }
    }

    my %seen_pair;
    for my $group (@groups) {
        for my $token ( @{ $group->{bots} } ) {
            my $key = "$group->{chat_id}\0$token";
            die "D2TG::Config::Flags::bot_groups: duplicate (chat_id, bot token) pair - "
              . "chat_id $group->{chat_id} is configured with the same bot token "
              . "more than once (check for an explicit --chat_id/--bot pair that "
              . "exactly duplicates D2TG_CHAT_ID/D2TG_TOKEN)\n"
              if $seen_pair{$key}++;
        }
    }

    my %seen_token_at;
    for my $group (@groups) {
        for my $token ( @{ $group->{bots} } ) {
            if ( exists $seen_token_at{$token} && $seen_token_at{$token} ne $group->{chat_id} ) {
                die "D2TG::Config::Flags::bot_groups: bot token "
                  . D2TG::Config::masked_token($token)
                  . " is configured under two different chat_id groups ("
                  . "$seen_token_at{$token} and $group->{chat_id}) - one Telegram bot "
                  . "token can only be long-polled by one consumer at a time, so this "
                  . "would race the same shared offset row regardless of chat_id\n";
            }
            $seen_token_at{$token} = $group->{chat_id};
        }
    }

    return ( \@groups, @rest );
}

1;
