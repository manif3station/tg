use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use File::Temp qw(tempfile tempdir);
use File::Spec;
use JSON::PP qw(decode_json);
use HTTP::Response;
use Test::MandatoryDb qw(setup_mandatory_db_env);

require D2TG::Telegram;

# TGT-103 (user-supplied feature-gap analysis, /tmp/missing.md item 1):
# the old ~/skills/tg blueprint had dedicated senders for pushing a local
# file to Telegram as a photo or document message - the new skill had no
# outbound-media primitive at all. send_photo/send_document mirror
# send_voice's own multipart pattern exactly.

package Fake::UA;

sub new {
    my ( $class, %args ) = @_;
    return bless { responses => $args{responses} || [], calls => [] }, $class;
}

sub request {
    my ( $self, $req ) = @_;
    push @{ $self->{calls} }, { method => 'request', url => $req->uri->as_string, req => $req };
    return shift @{ $self->{responses} };
}

package main;

sub http_response {
    my (%args) = @_;
    my $res = HTTP::Response->new( $args{code} // 200, $args{message} // 'OK' );
    $res->header( 'Content-Type' => 'application/json; charset=utf-8' );
    $res->content( $args{content} ) if defined $args{content};
    return $res;
}

{
    my ( $fh, $path ) = tempfile( SUFFIX => '.jpg' );
    print {$fh} 'fake jpeg bytes';
    close $fh;

    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":5}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    my $result = $tg->send_photo( 42, $path );

    is( scalar @{ $ua->{calls} }, 1, 'send_photo makes exactly one HTTP call' );
    like( $ua->{calls}[0]{url}, qr{/sendPhoto$}, 'called the sendPhoto endpoint' );
    like(
        $ua->{calls}[0]{req}->header('Content-Type'),
        qr{^multipart/form-data; boundary=},
        'send_photo uses a multipart/form-data content type'
    );
    like( $ua->{calls}[0]{req}->content, qr/fake jpeg bytes/, 'the photo file bytes are included in the request body' );
    like( $ua->{calls}[0]{req}->content, qr/name="chat_id"/, 'the chat_id form field is included' );
    is( $result->{message_id}, 5, 'send_photo returns the mocked Telegram result' );

    unlink $path;
}

{
    my ( $fh, $path ) = tempfile( SUFFIX => '.pdf' );
    print {$fh} 'fake pdf bytes';
    close $fh;

    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":6}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    my $result = $tg->send_document( 42, $path, caption => 'here is the receipt' );

    is( scalar @{ $ua->{calls} }, 1, 'send_document makes exactly one HTTP call' );
    like( $ua->{calls}[0]{url}, qr{/sendDocument$}, 'called the sendDocument endpoint' );
    like( $ua->{calls}[0]{req}->content, qr/fake pdf bytes/, 'the document file bytes are included in the request body' );
    like( $ua->{calls}[0]{req}->content, qr/name="caption"/, 'a caption form field is included when given' );
    like( $ua->{calls}[0]{req}->content, qr/here is the receipt/, 'the caption text is included in the request body' );
    is( $result->{message_id}, 6, 'send_document returns the mocked Telegram result' );

    unlink $path;
}

{
    # reply_to_message_id threading, matching send_voice's own support.
    my ( $fh, $path ) = tempfile( SUFFIX => '.jpg' );
    print {$fh} 'fake jpeg bytes';
    close $fh;

    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":7}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    $tg->send_photo( 42, $path, reply_to_message_id => 99 );

    like( $ua->{calls}[0]{req}->content, qr/name="reply_to_message_id"/, 'reply_to_message_id form field is included when given' );
    like( $ua->{calls}[0]{req}->content, qr/\b99\b/, 'the reply_to_message_id value is included' );

    unlink $path;
}

{
    my $ua = Fake::UA->new( responses => [] );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    eval { $tg->send_photo( 42, '/nonexistent/path/does-not-exist.jpg' ) };
    like( $@, qr/cannot read/, 'send_photo dies clearly when the file cannot be read' );
    is( scalar @{ $ua->{calls} }, 0, 'no HTTP call is made when the photo file is unreadable' );
}

{
    my $ua = Fake::UA->new( responses => [] );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    eval { $tg->send_document( 42, '/nonexistent/path/does-not-exist.pdf' ) };
    like( $@, qr/cannot read/, 'send_document dies clearly when the file cannot be read' );
    is( scalar @{ $ua->{calls} }, 0, 'no HTTP call is made when the document file is unreadable' );
}

{
    # CLI-level integration: cli/send.pl refuses cleanly (no network
    # call) on a missing file, before ever constructing D2TG::Telegram.
    my $send_cli    = File::Spec->catfile( $Bin, '..', 'cli', 'send.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my $err_file = "/tmp/d2tg-79-stderr.$$";
    my $out      = `$send_cli 42 /nonexistent/path/does-not-exist.jpg 2>$err_file`;
    my $rc       = $? >> 8;
    my $err      = do { open my $fh, '<', $err_file or die $!; local $/; <$fh> };
    unlink $err_file;

    is( $rc, 1, 'cli/send.pl refuses with exit 1 on a missing file' );
    like( $err, qr/file not found/, 'the error names the missing file, not an opaque Telegram error' );
    is( $out, '', 'nothing printed to stdout on refusal' );
}

{
    # CLI-level: a non-numeric chat_id hits the Usage refusal before any
    # file check or network call, matching cli/reply.pl's own guard.
    my $send_cli    = File::Spec->catfile( $Bin, '..', 'cli', 'send.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my $err_file = "/tmp/d2tg-79-stderr.$$";
    my $out      = `$send_cli not-a-number /some/file.jpg 2>$err_file`;
    my $rc       = $? >> 8;
    my $err      = do { open my $fh, '<', $err_file or die $!; local $/; <$fh> };
    unlink $err_file;

    is( $rc, 2, 'cli/send.pl refuses with exit 2 on a non-numeric chat_id' );
    like( $err, qr/Usage: d2 tg\.send/, 'the Usage message is printed' );
}

{
    # Codex review finding: --caption/--reply-to-message-id given AFTER
    # chat_id/file_path used to be silently dropped (accepted
    # syntactically, sent the file with neither) - must now refuse
    # instead, matching TGT-107's own "unrecognized/misplaced argument
    # refuses, never silently ignored" principle.
    my $send_cli    = File::Spec->catfile( $Bin, '..', 'cli', 'send.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my ( $fh, $path ) = tempfile( SUFFIX => '.jpg' );
    print {$fh} 'fake jpeg bytes';
    close $fh;

    my $err_file = "/tmp/d2tg-79-stderr.$$";
    my $out      = `$send_cli 42 $path --caption hello 2>$err_file`;
    my $rc       = $? >> 8;
    my $err      = do { open my $fh2, '<', $err_file or die $!; local $/; <$fh2> };
    unlink $err_file;
    unlink $path;

    is( $rc, 2, 'a trailing --caption after chat_id/file_path refuses (exit 2), never silently dropped' );
    like( $err, qr/Usage: d2 tg\.send/, 'the Usage message is printed, not a silent success' );
    is( $out, '', 'the file is never sent when trailing arguments are refused' );
}

{
    # Codex review finding: a directory (or other non-regular file) must
    # be refused by -f, not accepted by a bare -e check.
    my $send_cli    = File::Spec->catfile( $Bin, '..', 'cli', 'send.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my $a_directory = tempdir( CLEANUP => 1 );

    my $err_file = "/tmp/d2tg-79-stderr.$$";
    my $out      = `$send_cli 42 $a_directory 2>$err_file`;
    my $rc       = $? >> 8;
    my $err      = do { open my $fh, '<', $err_file or die $!; local $/; <$fh> };
    unlink $err_file;

    is( $rc, 1, 'a directory passed as file_path is refused, not accepted' );
    like( $err, qr/file not found/, 'the refusal message is the same clear one as a missing file' );
}

done_testing();
