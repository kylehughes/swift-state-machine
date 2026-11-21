// Each pair of failure spellings names one type, as the compiler checks: the router's generated method throws the first
// spelling, which each candidate's typed throw converts to, and the client catches exactly that type.
import StateMachine

public struct Wrap<T>: Error { public init() {} }

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    protocol P {}
    protocol Q {}
    struct Bad: Error {}
    typealias Same = Bad
    typealias BareP = P
    typealias AnyP = any P
    typealias Id<T> = T
    typealias Constant<T> = P
    protocol R {}
    typealias PQ = P & Q
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case alias, qualified, array, optional, dictionary, existential, composition, parentheses, attributes, nonthrowing, untyped, existentialMetatype, parenthesizedMetatype, aliasMetatype, genericBodyMetatype, metatypeOfExistential, protocolMetatype, substitutedMetatype, metatypeOfMetatype, flattened, deduplicated, arrayMetatype, optionalMetatype }
    @Route(on: Input.alias)
    fileprivate static func pickAlias(_ source: Idle) -> Route.PickAlias { .aliasFirst }
    @Transition(on: Input.alias)
    fileprivate static func aliasFirst(_ source: Idle) throws(Same) -> Idle { Idle() }
    @Transition(on: Input.alias)
    fileprivate static func aliasSecond(_ source: Idle) throws(Bad) -> Idle { Idle() }
    @Route(on: Input.qualified)
    fileprivate static func pickQualified(_ source: Idle) -> Route.PickQualified { .qualifiedFirst }
    @Transition(on: Input.qualified)
    fileprivate static func qualifiedFirst(_ source: Idle) throws(Self.Bad) -> Idle { Idle() }
    @Transition(on: Input.qualified)
    fileprivate static func qualifiedSecond(_ source: Idle) throws(Flow.Bad) -> Idle { Idle() }
    @Route(on: Input.array)
    fileprivate static func pickArray(_ source: Idle) -> Route.PickArray { .arrayFirst }
    @Transition(on: Input.array)
    fileprivate static func arrayFirst(_ source: Idle) throws(Wrap<[Swift::Int]>) -> Idle { Idle() }
    @Transition(on: Input.array)
    fileprivate static func arraySecond(_ source: Idle) throws(Wrap<Swift::Array<Swift::Int>>) -> Idle { Idle() }
    @Route(on: Input.optional)
    fileprivate static func pickOptional(_ source: Idle) -> Route.PickOptional { .optionalFirst }
    @Transition(on: Input.optional)
    fileprivate static func optionalFirst(_ source: Idle) throws(Wrap<Swift::Int?>) -> Idle { Idle() }
    @Transition(on: Input.optional)
    fileprivate static func optionalSecond(_ source: Idle) throws(Wrap<Swift::Optional<Swift::Int>>) -> Idle { Idle() }
    @Route(on: Input.dictionary)
    fileprivate static func pickDictionary(_ source: Idle) -> Route.PickDictionary { .dictionaryFirst }
    @Transition(on: Input.dictionary)
    fileprivate static func dictionaryFirst(_ source: Idle) throws(Wrap<[Swift::Int: Swift::Int]>) -> Idle { Idle() }
    @Transition(on: Input.dictionary)
    fileprivate static func dictionarySecond(_ source: Idle) throws(Wrap<Swift::Dictionary<Swift::Int, Swift::Int>>) -> Idle { Idle() }
    @Route(on: Input.existential)
    fileprivate static func pickExistential(_ source: Idle) -> Route.PickExistential { .existentialFirst }
    @Transition(on: Input.existential)
    fileprivate static func existentialFirst(_ source: Idle) throws(Wrap<any P>) -> Idle { Idle() }
    @Transition(on: Input.existential)
    fileprivate static func existentialSecond(_ source: Idle) throws(Wrap<P>) -> Idle { Idle() }
    @Route(on: Input.composition)
    fileprivate static func pickComposition(_ source: Idle) -> Route.PickComposition { .compositionFirst }
    @Transition(on: Input.composition)
    fileprivate static func compositionFirst(_ source: Idle) throws(Wrap<any P & Q>) -> Idle { Idle() }
    @Transition(on: Input.composition)
    fileprivate static func compositionSecond(_ source: Idle) throws(Wrap<any Q & P>) -> Idle { Idle() }
    @Route(on: Input.parentheses)
    fileprivate static func pickParentheses(_ source: Idle) -> Route.PickParentheses { .parenthesesFirst }
    @Transition(on: Input.parentheses)
    fileprivate static func parenthesesFirst(_ source: Idle) throws(Wrap<(P)>) -> Idle { Idle() }
    @Transition(on: Input.parentheses)
    fileprivate static func parenthesesSecond(_ source: Idle) throws(Wrap<P>) -> Idle { Idle() }
    @Route(on: Input.attributes)
    fileprivate static func pickAttributes(_ source: Idle) -> Route.PickAttributes { .attributesFirst }
    @Transition(on: Input.attributes)
    fileprivate static func attributesFirst(_ source: Idle) throws(Wrap<@Sendable @MainActor () -> Swift::Int>) -> Idle { Idle() }
    @Transition(on: Input.attributes)
    fileprivate static func attributesSecond(_ source: Idle) throws(Wrap<@MainActor @Sendable () -> Swift::Int>) -> Idle { Idle() }
    @Route(on: Input.nonthrowing)
    fileprivate static func pickNonthrowing(_ source: Idle) -> Route.PickNonthrowing { .nonthrowingFirst }
    @Transition(on: Input.nonthrowing)
    fileprivate static func nonthrowingFirst(_ source: Idle) throws(Wrap<() throws(Swift::Never) -> Swift::Int>) -> Idle { Idle() }
    @Transition(on: Input.nonthrowing)
    fileprivate static func nonthrowingSecond(_ source: Idle) throws(Wrap<() -> Swift::Int>) -> Idle { Idle() }
    @Route(on: Input.untyped)
    fileprivate static func pickUntyped(_ source: Idle) -> Route.PickUntyped { .untypedFirst }
    @Transition(on: Input.untyped)
    fileprivate static func untypedFirst(_ source: Idle) throws(Wrap<() throws(any Swift::Error) -> Swift::Int>) -> Idle { Idle() }
    @Transition(on: Input.untyped)
    fileprivate static func untypedSecond(_ source: Idle) throws(Wrap<() throws -> Swift::Int>) -> Idle { Idle() }
    @Route(on: Input.existentialMetatype)
    fileprivate static func pickExistentialMetatype(_ source: Idle) -> Route.PickExistentialMetatype { .existentialMetatypeFirst }
    @Transition(on: Input.existentialMetatype)
    fileprivate static func existentialMetatypeFirst(_ source: Idle) throws(Wrap<P.Type>) -> Idle { Idle() }
    @Transition(on: Input.existentialMetatype)
    fileprivate static func existentialMetatypeSecond(_ source: Idle) throws(Wrap<any P.Type>) -> Idle { Idle() }
    @Route(on: Input.parenthesizedMetatype)
    fileprivate static func pickParenthesizedMetatype(_ source: Idle) -> Route.PickParenthesizedMetatype { .parenthesizedMetatypeFirst }
    @Transition(on: Input.parenthesizedMetatype)
    fileprivate static func parenthesizedMetatypeFirst(_ source: Idle) throws(Wrap<(P).Type>) -> Idle { Idle() }
    @Transition(on: Input.parenthesizedMetatype)
    fileprivate static func parenthesizedMetatypeSecond(_ source: Idle) throws(Wrap<any P.Type>) -> Idle { Idle() }
    @Route(on: Input.aliasMetatype)
    fileprivate static func pickAliasMetatype(_ source: Idle) -> Route.PickAliasMetatype { .aliasMetatypeFirst }
    @Transition(on: Input.aliasMetatype)
    fileprivate static func aliasMetatypeFirst(_ source: Idle) throws(Wrap<BareP.Type>) -> Idle { Idle() }
    @Transition(on: Input.aliasMetatype)
    fileprivate static func aliasMetatypeSecond(_ source: Idle) throws(Wrap<any P.Type>) -> Idle { Idle() }
    @Route(on: Input.genericBodyMetatype)
    fileprivate static func pickGenericBodyMetatype(_ source: Idle) -> Route.PickGenericBodyMetatype { .genericBodyMetatypeFirst }
    @Transition(on: Input.genericBodyMetatype)
    fileprivate static func genericBodyMetatypeFirst(_ source: Idle) throws(Wrap<Constant<Swift::Int>.Type>) -> Idle { Idle() }
    @Transition(on: Input.genericBodyMetatype)
    fileprivate static func genericBodyMetatypeSecond(_ source: Idle) throws(Wrap<any P.Type>) -> Idle { Idle() }
    @Route(on: Input.metatypeOfExistential)
    fileprivate static func pickMetatypeOfExistential(_ source: Idle) -> Route.PickMetatypeOfExistential { .metatypeOfExistentialFirst }
    @Transition(on: Input.metatypeOfExistential)
    fileprivate static func metatypeOfExistentialFirst(_ source: Idle) throws(Wrap<AnyP.Type>) -> Idle { Idle() }
    @Transition(on: Input.metatypeOfExistential)
    fileprivate static func metatypeOfExistentialSecond(_ source: Idle) throws(Wrap<(any P).Type>) -> Idle { Idle() }
    @Route(on: Input.protocolMetatype)
    fileprivate static func pickProtocolMetatype(_ source: Idle) -> Route.PickProtocolMetatype { .protocolMetatypeFirst }
    @Transition(on: Input.protocolMetatype)
    fileprivate static func protocolMetatypeFirst(_ source: Idle) throws(Wrap<P.Protocol>) -> Idle { Idle() }
    @Transition(on: Input.protocolMetatype)
    fileprivate static func protocolMetatypeSecond(_ source: Idle) throws(Wrap<(any P).Type>) -> Idle { Idle() }
    @Route(on: Input.substitutedMetatype)
    fileprivate static func pickSubstitutedMetatype(_ source: Idle) -> Route.PickSubstitutedMetatype { .substitutedMetatypeFirst }
    @Transition(on: Input.substitutedMetatype)
    fileprivate static func substitutedMetatypeFirst(_ source: Idle) throws(Wrap<Id<P>.Type>) -> Idle { Idle() }
    @Transition(on: Input.substitutedMetatype)
    fileprivate static func substitutedMetatypeSecond(_ source: Idle) throws(Wrap<(any P).Type>) -> Idle { Idle() }
    @Route(on: Input.metatypeOfMetatype)
    fileprivate static func pickMetatypeOfMetatype(_ source: Idle) -> Route.PickMetatypeOfMetatype { .metatypeOfMetatypeFirst }
    @Transition(on: Input.metatypeOfMetatype)
    fileprivate static func metatypeOfMetatypeFirst(_ source: Idle) throws(Wrap<P.Type.Type>) -> Idle { Idle() }
    @Transition(on: Input.metatypeOfMetatype)
    fileprivate static func metatypeOfMetatypeSecond(_ source: Idle) throws(Wrap<any P.Type.Type>) -> Idle { Idle() }
    @Route(on: Input.flattened)
    fileprivate static func pickFlattened(_ source: Idle) -> Route.PickFlattened { .flattenedFirst }
    @Transition(on: Input.flattened)
    fileprivate static func flattenedFirst(_ source: Idle) throws(Wrap<any PQ & R>) -> Idle { Idle() }
    @Transition(on: Input.flattened)
    fileprivate static func flattenedSecond(_ source: Idle) throws(Wrap<any P & Q & R>) -> Idle { Idle() }
    @Route(on: Input.deduplicated)
    fileprivate static func pickDeduplicated(_ source: Idle) -> Route.PickDeduplicated { .deduplicatedFirst }
    @Transition(on: Input.deduplicated)
    fileprivate static func deduplicatedFirst(_ source: Idle) throws(Wrap<any P & P>) -> Idle { Idle() }
    @Transition(on: Input.deduplicated)
    fileprivate static func deduplicatedSecond(_ source: Idle) throws(Wrap<any P>) -> Idle { Idle() }
    @Route(on: Input.arrayMetatype)
    fileprivate static func pickArrayMetatype(_ source: Idle) -> Route.PickArrayMetatype { .arrayMetatypeFirst }
    @Transition(on: Input.arrayMetatype)
    fileprivate static func arrayMetatypeFirst(_ source: Idle) throws(Wrap<[Swift::Int].Type>) -> Idle { Idle() }
    @Transition(on: Input.arrayMetatype)
    fileprivate static func arrayMetatypeSecond(_ source: Idle) throws(Wrap<Swift::Array<Swift::Int>.Type>) -> Idle { Idle() }
    @Route(on: Input.optionalMetatype)
    fileprivate static func pickOptionalMetatype(_ source: Idle) -> Route.PickOptionalMetatype { .optionalMetatypeFirst }
    @Transition(on: Input.optionalMetatype)
    fileprivate static func optionalMetatypeFirst(_ source: Idle) throws(Wrap<Swift::Int?.Type>) -> Idle { Idle() }
    @Transition(on: Input.optionalMetatype)
    fileprivate static func optionalMetatypeSecond(_ source: Idle) throws(Wrap<Swift::Optional<Swift::Int>.Type>) -> Idle { Idle() }
}
extension Flow {
    static func check(_ observed: Observed<Idle>) {
        do throws(Same) { _ = try observed.pickAlias() } catch { _ = error }
        do throws(Self.Bad) { _ = try observed.pickQualified() } catch { _ = error }
        do throws(Wrap<[Swift::Int]>) { _ = try observed.pickArray() } catch { _ = error }
        do throws(Wrap<Swift::Int?>) { _ = try observed.pickOptional() } catch { _ = error }
        do throws(Wrap<[Swift::Int: Swift::Int]>) { _ = try observed.pickDictionary() } catch { _ = error }
        do throws(Wrap<any P>) { _ = try observed.pickExistential() } catch { _ = error }
        do throws(Wrap<any P & Q>) { _ = try observed.pickComposition() } catch { _ = error }
        do throws(Wrap<(P)>) { _ = try observed.pickParentheses() } catch { _ = error }
        do throws(Wrap<@Sendable @MainActor () -> Swift::Int>) { _ = try observed.pickAttributes() } catch { _ = error }
        do throws(Wrap<() throws(Swift::Never) -> Swift::Int>) { _ = try observed.pickNonthrowing() } catch { _ = error }
        do throws(Wrap<() throws(any Swift::Error) -> Swift::Int>) { _ = try observed.pickUntyped() } catch { _ = error }
        do throws(Wrap<P.Type>) { _ = try observed.pickExistentialMetatype() } catch { _ = error }
        do throws(Wrap<(P).Type>) { _ = try observed.pickParenthesizedMetatype() } catch { _ = error }
        do throws(Wrap<BareP.Type>) { _ = try observed.pickAliasMetatype() } catch { _ = error }
        do throws(Wrap<Constant<Swift::Int>.Type>) { _ = try observed.pickGenericBodyMetatype() } catch { _ = error }
        do throws(Wrap<AnyP.Type>) { _ = try observed.pickMetatypeOfExistential() } catch { _ = error }
        do throws(Wrap<P.Protocol>) { _ = try observed.pickProtocolMetatype() } catch { _ = error }
        do throws(Wrap<Id<P>.Type>) { _ = try observed.pickSubstitutedMetatype() } catch { _ = error }
        do throws(Wrap<P.Type.Type>) { _ = try observed.pickMetatypeOfMetatype() } catch { _ = error }
        do throws(Wrap<any PQ & R>) { _ = try observed.pickFlattened() } catch { _ = error }
        do throws(Wrap<any P & P>) { _ = try observed.pickDeduplicated() } catch { _ = error }
        do throws(Wrap<[Swift::Int].Type>) { _ = try observed.pickArrayMetatype() } catch { _ = error }
        do throws(Wrap<Swift::Int?.Type>) { _ = try observed.pickOptionalMetatype() } catch { _ = error }
    }
}
