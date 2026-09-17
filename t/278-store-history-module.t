use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-278 (found via a wc -l sweep run as TGT-277's own pipeline-
# continuity backlog check): D2TG::Store.pm was 1378 lines (838 of
# code, ~540 of embedded POD never extracted to Store.pod) - far over
# the board's 500-line-per-module cap. Surveyed its own function
# clusters: access control (is_allowed/add_pending/approve/
# pending_chat_ids), offset tracking, message history (record_message/
# get_message/get_attachment_path/mark_read/is_read/unread_messages/
# recent_messages/messages_in_range - 8 functions, ~148 lines, the
# largest single cohesive cluster), retry-queue forwarders (already
# thin), sent-reply audit (record_sent_text/record_sent_voice/
# text_only_replies/is_recent_duplicate_reply), prune_history, and the
# connection/schema core (new/_ensure_schema/_seed_admin, which must
# stay). The message-history cluster was picked first: it's the
# largest, and its own functions only need $dbh, not any of the
# access-control/offset/retry-queue state.

require D2TG::Store;
require D2TG::Store::History;

for my $name (
    qw(record_message get_message get_attachment_path mark_read is_read
      unread_messages recent_messages messages_in_range)
  )
{
    ok( D2TG::Store::History->can($name), "D2TG::Store::History owns $name" );
}

done_testing();
