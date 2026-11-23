/// Records kept on the device as a journal of whole field-group writes, where
/// a unit's value is every write nobody has replaced (codraw DESIGN B2, §1).
library;

export 'src/canonical_json.dart'
    show canonicalJson, canonicalJsonOrNull, maxSafeInteger;
export 'src/journal_store.dart'
    show InMemoryJournalStore, JournalEntry, JournalStore, JournalTransaction;
export 'src/record_journal.dart'
    show RecordJournal, Serializer, isolateLocalQueue;
export 'src/unit_write.dart'
    show
        Admission,
        Admitted,
        ContentWrite,
        DeleteWrite,
        Door,
        Refusal,
        Refused,
        RestoreWrite,
        UnitWrite,
        UnitWriteDraft;
export 'src/values.dart'
    show
        CanonicalObject,
        HashedIdentityFamily,
        Identity,
        IdentityFamily,
        RecordId,
        RecordSchema,
        ResolvedIdentity,
        Salt,
        UnitName,
        WriteId;
export 'src/view.dart'
    show DrawnRecord, GhostRecord, HiddenRecord, RecordView, UnitState;
