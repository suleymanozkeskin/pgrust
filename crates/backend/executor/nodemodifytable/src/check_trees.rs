//! Parsed CHECK constraint trees, kept per relation for the session.
//!
//! C ExecRelCheck (execMain.c:1805) runs stringToNode on every `ccbin`
//! string once per statement and result relation. This cache keeps the
//! stringToNode output per relation and gives each statement a deep copy,
//! because the later steps (expand_generated_columns_in_expr,
//! eval_const_expressions) may change the tree in place.
//!
//! An entry is used only when its stored `ccbin` texts and enforcement flags
//! equal the relation's current ones. stringToNode depends only on the text,
//! so a hit gives the same tree a new parse gives, and the cache needs no
//! relcache invalidation callback (the backend has a fixed number of callback
//! slots). A relation whose constraints changed gets a new entry, and the old
//! entry's context is freed. At most `MAX_CACHED_RELATIONS` relations are
//! kept; an insert past that bound first frees every entry.

use core::cell::RefCell;
use core::mem::ManuallyDrop;

use mcx::{Mcx, MemoryContext, PgHashMap, PgString, PgVec};
use types_core::Oid;
use types_error::PgResult;
use types_nodes::Node;
use types_tuple::tupdesc::ConstrCheck;

/// Relations with cached trees in one session.
const MAX_CACHED_RELATIONS: usize = 256;

/// One constraint of a relation, as the executor compiles it.
pub(crate) enum ParsedCheck<'mcx> {
    /// `ccenforced` is false: the constraint is not evaluated.
    NotEnforced,
    /// The stringToNode output of `ccbin`, owned by the caller's context.
    Tree(Node<'mcx>),
}

enum CachedCheck {
    NotEnforced,
    Tree { ccbin: PgString<'static>, tree: Node<'static> },
}

struct RelationChecks {
    checks: PgVec<'static, CachedCheck>,
    // Owns `checks`, the texts and the trees; declared last so it is freed
    // after the vector is dropped.
    _ctx: Box<MemoryContext>,
}

struct CheckTreeCache {
    root: &'static MemoryContext,
    relations: PgHashMap<'static, Oid, RelationChecks>,
}

thread_local! {
    static CACHE: RefCell<Option<ManuallyDrop<CheckTreeCache>>> = const { RefCell::new(None) };
}

fn with_cache<R>(f: impl FnOnce(&mut CheckTreeCache) -> R) -> R {
    CACHE.with(|cell| {
        let mut slot = cell.borrow_mut();
        let cache = slot.get_or_insert_with(|| {
            let root = mcx::session_root("CheckConstraintTrees");
            ManuallyDrop::new(CheckTreeCache {
                root,
                relations: PgHashMap::with_capacity_in(8, root.mcx()),
            })
        });
        f(cache)
    })
}

impl RelationChecks {
    /// True when every stored constraint has the text and enforcement flag
    /// of the matching entry in `checks`.
    fn matches(&self, checks: &[ConstrCheck<'_>]) -> bool {
        self.checks.len() == checks.len()
            && self.checks.iter().zip(checks).all(|(cached, current)| match cached {
                CachedCheck::NotEnforced => !current.ccenforced,
                CachedCheck::Tree { ccbin, .. } => {
                    current.ccenforced
                        && current.ccbin.as_ref().is_some_and(|text| text.as_str() == ccbin.as_str())
                }
            })
    }

    /// Deep copies of the stored trees, in constraint order, in `mcx`.
    fn copy_out<'mcx>(&self, mcx: Mcx<'mcx>) -> PgResult<PgVec<'mcx, ParsedCheck<'mcx>>> {
        let mut out = PgVec::new_in(mcx);
        out.try_reserve_exact(self.checks.len())
            .map_err(|_| mcx.oom(self.checks.len() * core::mem::size_of::<ParsedCheck<'_>>()))?;
        for cached in self.checks.iter() {
            out.push(match cached {
                CachedCheck::NotEnforced => ParsedCheck::NotEnforced,
                CachedCheck::Tree { tree, .. } => ParsedCheck::Tree(copyfuncs::copy_object(mcx, *tree)?),
            });
        }
        Ok(out)
    }

    /// Parses every enforced constraint of `checks` into a new context under
    /// `root`. Runs outside the cache borrow: stringToNode can read the
    /// catalog, and catalog reads can run invalidation callbacks.
    fn parse(root: &'static MemoryContext, checks: &[ConstrCheck<'_>]) -> PgResult<Self> {
        let ctx = Box::new(root.new_child("CHECK constraint trees"));
        // SAFETY: the context is boxed (fixed address) and owned by the
        // returned entry, which drops `checks` (the only user of this handle)
        // before the context.
        let cmcx: Mcx<'static> = unsafe { core::mem::transmute::<Mcx<'_>, Mcx<'static>>(ctx.mcx()) };
        let mut stored = PgVec::new_in(cmcx);
        stored
            .try_reserve_exact(checks.len())
            .map_err(|_| cmcx.oom(checks.len() * core::mem::size_of::<CachedCheck>()))?;
        for check in checks {
            if !check.ccenforced {
                stored.push(CachedCheck::NotEnforced);
                continue;
            }
            let text = check.ccbin.as_ref().expect("ccbin");
            stored.push(CachedCheck::Tree {
                ccbin: text.clone_in(cmcx)?,
                tree: readfuncs::stringToNode(cmcx, text.as_str())?,
            });
        }
        Ok(RelationChecks { checks: stored, _ctx: ctx })
    }
}

/// The parsed form of every constraint in `checks` (the CHECK constraints
/// of relation `relid`, in relcache order), copied into `mcx`.
///
/// Effects: on a miss, parses the constraints and stores the result for
/// later statements, replacing a stale entry of the relation. Errors are
/// the errors of stringToNode and out-of-memory; after an error the cache
/// holds no entry built from this call.
pub(crate) fn parsed_checks<'mcx>(
    mcx: Mcx<'mcx>,
    relid: Oid,
    checks: &[ConstrCheck<'_>],
) -> PgResult<PgVec<'mcx, ParsedCheck<'mcx>>> {
    let hit = with_cache(|cache| match cache.relations.get(&relid) {
        Some(entry) if entry.matches(checks) => Some(entry.copy_out(mcx)),
        Some(_) | None => None,
    });
    if let Some(copied) = hit {
        return copied;
    }
    let root = with_cache(|cache| cache.root);
    let entry = RelationChecks::parse(root, checks)?;
    let copied = entry.copy_out(mcx)?;
    with_cache(|cache| {
        if cache.relations.len() >= MAX_CACHED_RELATIONS && !cache.relations.contains_key(&relid) {
            cache.relations.clear();
        }
        drop(cache.relations.insert(relid, entry));
    });
    Ok(copied)
}
