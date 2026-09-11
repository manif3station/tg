use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

# TGT-182 (found via a scheduled improvement hunt): the 5-line
# multipart reply_to_message_id field construction ("validate, then
# if defined append a form-data fragment to $body") appeared
# identically in both send_voice and _send_file (backing
# send_photo/send_document) - extracted into a single helper, matching
# this project's own established "found it twice, extract it"
# convention (TGT-167/170/171/172/177/181). The real behavioral
# guarantee (correct multipart bytes, correct per-method error
# message) is t/32-message-id-and-reply-threading.t's and
# t/79-outbound-media-send.t's job, already passing unchanged - this
# file only guards the structural refactor itself.

my $source_path = "$Bin/../lib/D2TG/Telegram.pm";
open my $fh, '<', $source_path or die $!;
local $/;
my $source = <$fh>;
close $fh;

my $duplicate_pattern_count = () = $source =~ /
    if\ \(\ defined\ \$opts\{reply_to_message_id\}\ \)\ \{\n
    \s*\$body\ \.=\ "--\$boundary\\r\\n"\n
/gx;

is( $duplicate_pattern_count, 0,
    'the duplicated multipart reply_to_message_id field-construction block appears 0 times outside the new helper (TGT-182 AC)' );

my $helper_call_count = () = $source =~ /_append_reply_to_message_id_field\(/g;

is( $helper_call_count, 2,
    'the new helper is called from exactly 2 places - send_voice and _send_file' );

# 2nd Codex QA-stage review round finding: the first attempt at
# per-site anchoring used unbounded '.*?' with /s, which still could
# not prove a call sits INSIDE its claimed subroutine - it could match
# across a subroutine boundary just as easily as within one. Properly
# bound the search this time: isolate each named subroutine's own
# source region (from "sub NAME {" to the next top-level "sub " or end
# of file) and assert the helper is called exactly once within THAT
# extracted region, not just "found somewhere in the whole file near
# some text". This is still a source-text regex, not a full parser
# (nested braces inside a sub could in principle confuse the "next sub
# starts here" boundary, though none exist in either of these two
# subs today) - a real, documented, and now much narrower limitation
# than a global count or an unbounded proximity match.
sub extract_sub_body {
    my ( $source, $sub_name ) = @_;
    return $1 if $source =~ /^sub\s+\Q$sub_name\E\s*\{(.*?)^sub\s/ms;
    return $1 if $source =~ /^sub\s+\Q$sub_name\E\s*\{(.*)\z/ms;
    return undef;
}

for my $sub_name (qw(send_voice _send_file)) {
    my $body = extract_sub_body( $source, $sub_name );
    ok( defined $body, "found ${sub_name}'s own subroutine body in the source" );

    my $count_in_sub = () = ( $body // '' ) =~ /_append_reply_to_message_id_field\(/g;
    is( $count_in_sub, 1, "the helper is called exactly once WITHIN ${sub_name}'s own subroutine body (bounded extraction, not just proximity)" );
}

done_testing();
