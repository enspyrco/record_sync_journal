# record_sync_journal

Records kept on the device as a journal of whole field-group writes. Each write
names the writes its author saw, and a field group's value is every write nobody
has replaced: no clock, and nothing picks a winner.

Work in progress. The design is codraw's B2 (`docs/crucible/canvas-sync-order-authority/DESIGN.md`
in enspyrco/codraw); this package is its step 1a, generic over the record type.
