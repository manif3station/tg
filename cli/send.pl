#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;

use D2TG::Config;
use D2TG::Telegram;
use D2TG::Reply;

# TGT-103 (user-supplied feature-gap analysis, /tmp/missing.md item 1):
# the old ~/skills/tg blueprint had two dedicated senders for pushing a
# local file to Telegram as a photo or document message - this skill had
# no outbound-media primitive at all until this command. Thin CLI
# wrapper around D2TG::Telegram::send_photo/send_document.

my $db_alias;
my $bot_token;
my $caption;
my $reply_to_message_id;

while (@ARGV) {
    if ( $ARGV[0] eq '--db' || $ARGV[0] eq '-d' ) {
        shift @ARGV;
        $db_alias = eval { D2TG::Config::shift_flag_value( \@ARGV, '--db/-d' ) };
        if ($@) {
            print STDERR $@;
            exit 1;
        }
    }
    elsif ( $ARGV[0] eq '--bot' ) {
        if ( @ARGV >= 2 ) {
            ( $bot_token, @ARGV ) = D2TG::Reply::extract_bot_flag(@ARGV);
        }
        else {
            shift @ARGV;
        }
    }
    elsif ( $ARGV[0] eq '--caption' ) {
        shift @ARGV;
        $caption = eval { D2TG::Config::shift_flag_value( \@ARGV, '--caption' ) };
        if ($@) {
            print STDERR $@;
            exit 1;
        }
    }
    elsif ( $ARGV[0] eq '--reply-to-message-id' ) {
        shift @ARGV;
        $reply_to_message_id = eval { D2TG::Config::shift_flag_value( \@ARGV, '--reply-to-message-id' ) };
        if ($@) {
            print STDERR $@;
            exit 1;
        }
    }
    else {
        last;
    }
}

my $base_dir = eval { D2TG::Config::resolve_alias_dir( alias => $db_alias ) };
if ($@) {
    print STDERR $@;
    exit 1;
}

eval { D2TG::Config::require_existing_base_dir($base_dir) };
if ($@) {
    print STDERR $@;
    exit 1;
}

my ( $chat_id, $file_path ) = @ARGV;

if ( !defined $chat_id
    || $chat_id !~ /^-?\d+$/
    || !defined $file_path
    || !length $file_path
    || ( defined $reply_to_message_id && $reply_to_message_id !~ /^\d+$/ ) )
{
    print STDERR "Usage: d2 tg.send [--db <alias> | -d <alias>] [--bot <token>] <chat_id> <file_path> [--caption <text>] [--reply-to-message-id <id>]\n";
    exit 2;
}

if ( !-e $file_path ) {
    print STDERR "d2 tg.send: file not found: $file_path\n";
    exit 1;
}

# Decided by file extension, not content sniffing - simple and matches
# what Telegram itself expects (sendPhoto renders inline for common
# image formats; everything else works fine as sendDocument regardless).
my ($ext) = $file_path =~ /\.([^.]+)$/;
my $is_photo = defined $ext && lc($ext) =~ /^(?:jpe?g|png|gif|webp)$/;

my $telegram = D2TG::Telegram->new( token => $bot_token // D2TG::Config::token() );

my %opts;
$opts{caption}              = $caption              if defined $caption;
$opts{reply_to_message_id}  = $reply_to_message_id  if defined $reply_to_message_id;

my $result = eval {
    $is_photo
      ? $telegram->send_photo( $chat_id, $file_path, %opts )
      : $telegram->send_document( $chat_id, $file_path, %opts );
};
if ($@) {
    print STDERR $@;
    exit 1;
}

print "Sent " . ( $is_photo ? 'photo' : 'document' ) . " to $chat_id\n";

=head1 NAME

send - push a local file to a chat as a photo or document, dispatched as C<d2 tg.send>

=head1 SYNOPSIS

    d2 tg.send [--db <alias> | -d <alias>] [--bot <token>] <chat_id> <file_path> [--caption <text>] [--reply-to-message-id <id>]

=head1 DESCRIPTION

TGT-103 (user-supplied feature-gap analysis): the old C<~/skills/tg>
blueprint had two dedicated senders (one for images, one for any other
file type) that took a local file path and pushed it to Telegram - this
skill had no outbound-media primitive at all until this command. Thin
wrapper around L<D2TG::Telegram/send_photo> and
L<D2TG::Telegram/send_document>.

Whether the file is sent as a photo (renders inline in Telegram) or a
document (downloadable) is decided by its extension: C<.jpg>/C<.jpeg>/
C<.png>/C<.gif>/C<.webp> (case-insensitive) send as a photo; everything
else sends as a document. No content sniffing - Telegram itself accepts
any file type via C<sendDocument> regardless.

C<--db>/C<-d>, C<--bot>, C<--caption>, and C<--reply-to-message-id> may
appear in any order before C<chat_id>/C<file_path>. C<--caption> is
optional free text attached to the sent photo/document.
C<--reply-to-message-id> (numeric) threads the send under an existing
Telegram message, matching C<d2 tg.reply>'s own flag. C<--db>/C<-d>/
C<--bot> match C<d2 tg.reply>'s own leading-flag shape and validation
(L<D2TG::Config/shift_flag_value>).

C<chat_id> is validated as numeric and C<file_path> must exist on disk
before any network call is attempted - a missing or unreadable file
refuses with a clear message rather than an opaque Telegram API error.

=cut
