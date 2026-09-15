export type NatureActivité = 'artisanale' | 'commerciale' | 'libérale'

export type TypeActivité = 'vente' | 'service'

export type IRouIS = 'IR' | 'IS'

export type MéthodeImposition = 'barème standard' | 'taux personnalisé'

export type SituationFamiliale = 'célibataire' | 'couple' | 'veuf'

import * as O from 'effect/Option'
import { TFunction } from 'i18next'
import Engine from 'publicodes'
import { ReactNode } from 'react'

import { StatutType } from '@/components/StatutTag'
import { Montant } from '@/domaine/Montant'
import { MontantRécurrent } from '@/domaine/MontantRecurrent'
import { DottedName } from '@/domaine/publicodes/DottedName'
import { NomModèle } from '@/domaine/PublicodesSimulationConfig'
import { Quantité } from '@/domaine/Quantite'

import { IRouIS } from './imposition'
import { Question, Réponse } from './situation'

type ValeurDocumentée = {
	// TODO: remplacer documentationRule par DocumentationLink (un composant)
	documentationRule: DottedName
	// TODO: déplacer les warnings ici
	// warning?: ReactNode
}

export type MontantDocumenté = Montant & ValeurDocumentée
export type MontantRécurrentDocumenté = MontantRécurrent & ValeurDocumentée
export type QuantitéDocumentée = Quantité & ValeurDocumentée

export interface ModèleComparable {
	nom: NomModèle

	set: {
		chiffreDAffaires: (montant: O.Option<MontantRécurrent>) => void
		charges: (montant: O.Option<MontantRécurrent>) => void
		IRouIS?: (valeur: IRouIS) => void
		versementLibératoire?: (valeur: boolean) => void
		réponse: (
			...args: {
				[K in Question]: [question: K, valeur: Réponse<K>]
			}[Question]
		) => void
	}

	get: {
		engine: () => Engine<DottedName>
		statut: {
			étiquette: StatutType
			nom: string
			// TODO: ne plus retourner de trad, c'est le comparateur qui gère ça
			régime: (t: TFunction) => string
			imposition: () => ReactNode
		}
		revenu: () => {
			bénéfice: MontantRécurrentDocumenté
			revenuNetAprèsImpôt: MontantRécurrentDocumenté
		}
		dépenses: () => {
			cotisations: MontantRécurrentDocumenté
			impôt: MontantRécurrentDocumenté
		}
		retraite: () => ValeurDocumentée & {
			trimestres: QuantitéDocumentée
			revenuCotisé: MontantRécurrentDocumenté
			pointsComplémentaire: QuantitéDocumentée
			valeurPointComplémentaire: MontantRécurrentDocumenté
		}
		maladie: () => ValeurDocumentée & {
			indemnitésArrêtMaladie: MontantRécurrentDocumenté
			délaiAttente: QuantitéDocumentée
			indemnitésATMP?: MontantRécurrentDocumenté
			indemnitésATMPLongTerme?: MontantRécurrentDocumenté
		}
		parentalité: () => ValeurDocumentée & {
			indemnitésMaternitéPaternitéAdoption: MontantRécurrentDocumenté
			allocationNaissance?: MontantDocumenté
			allocationAdoption?: MontantDocumenté
		}
		invalidité: () => ValeurDocumentée & {
			pensionInvaliditéPartielle: MontantRécurrentDocumenté
			pensionInvaliditéTotale: MontantRécurrentDocumenté
			renteIncapacitéATMP?: MontantRécurrentDocumenté
		}
		décès: () => ValeurDocumentée & {
			pensionDeRéversion: MontantRécurrentDocumenté
			capitalDécès: MontantDocumenté
			capitalOrphelin?: MontantDocumenté
			renteDécèsATMP?: MontantRécurrentDocumenté
		}
		// gestion: () => {
		// 	coûtsDeCréation: Montant<'€'>
		// 	statutConjointe: (t: TFunction) => string
		// }
		warning?: () => {
			revenuTropBasPourIJ?: boolean
			seuilMicro?: Montant<'€/an'>
		}
	}
}

export type CatégorieComparée = keyof Omit<
	ModèleComparable['get'],
	'engine' | 'statut' | 'warning'
>
export type ÉlémentComparé<K extends CatégorieComparée> = Exclude<
	keyof ReturnType<ModèleComparable['get'][K]>,
	'documentationRule'
>

import * as O from 'effect/Option'

import { estPositif, Montant } from '@/domaine/Montant'
import { eurosParAn, MontantRécurrent } from '@/domaine/MontantRecurrent'
import { quantité, Quantité } from '@/domaine/Quantite'
import { Situation } from '@/domaine/Situation'

import { NatureActivité, TypeActivité } from './activite'
import { IRouIS, MéthodeImposition, SituationFamiliale } from './imposition'

export interface SituationComparée extends Situation {
	_type: 'comparaison-statuts'
	chiffreDAffaires: O.Option<MontantRécurrent>
	charges: O.Option<MontantRécurrent>
	IRouIS: IRouIS
	versementLibératoire: boolean
	natureActivité: NatureActivité
	typeActivité: TypeActivité
	activitéLibéraleRéglementée: boolean
	acre: boolean
	méthodeImposition: MéthodeImposition
	tauxImposition: O.Option<Quantité<'%'>>
	situationFamiliale: SituationFamiliale
	enfants: Quantité<'enfant'>
	parentIsolé: boolean
	autresRevenus: Montant<'€/an'>
	tva: boolean
}

export type Question = keyof Omit<
	SituationComparée,
	'chiffreDAffaires' | 'charges' | 'IRouIS' | 'versementLibératoire'
>

export type Réponse<T extends Question> = SituationComparée[T]

interface SituationComparéeValide extends SituationComparée {
	chiffreDAffaires: O.Some<MontantRécurrent>
}

export const initialSituationComparée: SituationComparée = {
	_tag: 'Situation',
	_type: 'comparaison-statuts',
	chiffreDAffaires: O.none(),
	charges: O.none(),
	IRouIS: 'IR',
	versementLibératoire: false,
	natureActivité: 'commerciale',
	typeActivité: 'vente',
	activitéLibéraleRéglementée: false,
	acre: false,
	tva: true,
	méthodeImposition: 'barème standard',
	tauxImposition: O.none(),
	situationFamiliale: 'célibataire',
	enfants: quantité(0, 'enfant'),
	parentIsolé: false,
	autresRevenus: eurosParAn(0),
}

export const estSituationValide = (
	situation: SituationComparée
): situation is SituationComparéeValide =>
	O.isSome(situation.chiffreDAffaires) &&
	estPositif(situation.chiffreDAffaires.value)

export const simulationEstCommencée = (situation: SituationComparée): boolean =>
	Object.keys(situation).some(
		(élémentSituation) =>
			situation[élémentSituation as keyof SituationComparée] !==
			initialSituationComparée[élémentSituation as keyof SituationComparée]
	)

export const annéeDeSimulation = (): number => new Date().getFullYear()

export const annéeDesRevenus = (
	dateAffiliation: Date,
	dateFinAffiliation?: Date
): number => {
	const minimum = dateAffiliation.getFullYear()
	const maximum = dateFinAffiliation?.getFullYear() ?? Infinity

	return Math.min(Math.max(annéeDeSimulation(), minimum), maximum)
}

import * as O from 'effect/Option'

import { PLAFOND_ANNUEL_SECURITE_SOCIALE } from '@/domaine/ConstantesSociales'
import { arrondirÀLEuro, estNégatif, fois, Montant } from '@/domaine/Montant'
import { euros } from '@/domaine/MontantPonctuel'
import {
	eurosParAn,
	moins,
	plus,
	toEurosParMois,
} from '@/domaine/MontantRecurrent'
import { valeurPourAnnée } from '@/domaine/ValeurAnnuelle'

import { annéeDesRevenus } from './annee-de-simulation'
import { joursAffiliésDansAnnée, joursDansAnnée } from './jours-affiliation'
import { SituationFrontalierSuisseValide } from './situation'

export const TAUX_COTISATION_MALADIE = 0.08
export const TAUX_ABATTEMENT_PASS = 0.25

export const plafondSécuritéSociale = (année: number): Montant<'€/an'> =>
	eurosParAn(valeurPourAnnée(PLAFOND_ANNUEL_SECURITE_SOCIALE, année))

export const abattementSécuritéSociale = (année: number): Montant<'€/an'> =>
	fois(plafondSécuritéSociale(année), TAUX_ABATTEMENT_PASS)

export interface CotisationMaladie {
	annuel: Montant<'€/an'>
	mensuel: Montant<'€/mois'>
	prorataAnnéePartielle: O.Option<Montant<'€'>>
}

export interface DécompositionCotisationMaladie extends CotisationMaladie {
	annéeRevenus: number
	salaires: Montant<'€/an'>
	autresRevenus: Montant<'€/an'>
	assiette: Montant<'€/an'>
	base: Montant<'€/an'>
	joursAffiliation: number
}

export const décomposeCotisationMaladie = (
	situation: SituationFrontalierSuisseValide
): DécompositionCotisationMaladie => {
	const dateAffiliation = situation.dateAffiliation.value
	const dateFinAffiliation = O.getOrUndefined(situation.dateFinAffiliation)
	const annéeRevenus = annéeDesRevenus(dateAffiliation, dateFinAffiliation)

	const salaires = situation.salaires.value
	const autresRevenus = O.getOrElse(situation.autresRevenus, () =>
		eurosParAn(0)
	)
	const assiette = plus(salaires, autresRevenus)

	const baseBrute = moins(assiette, abattementSécuritéSociale(annéeRevenus))
	const base = estNégatif(baseBrute) ? eurosParAn(0) : baseBrute

	const annuel = arrondirÀLEuro(fois(base, TAUX_COTISATION_MALADIE))
	const mensuel = arrondirÀLEuro(toEurosParMois(annuel))

	const joursAffiliation = joursAffiliésDansAnnée(
		dateAffiliation,
		dateFinAffiliation
	)
	const joursAnnée = joursDansAnnée(annéeRevenus)
	const prorataAnnéePartielle =
		joursAffiliation < joursAnnée
			? O.some(
					arrondirÀLEuro(euros((annuel.valeur * joursAffiliation) / joursAnnée))
				)
			: O.none()

	return {
		annéeRevenus,
		salaires,
		autresRevenus,
		assiette,
		base,
		joursAffiliation,
		annuel,
		mensuel,
		prorataAnnéePartielle,
	}
}

export const calculeCotisationMaladie = (
	situation: SituationFrontalierSuisseValide
): CotisationMaladie => {
	const { annuel, mensuel, prorataAnnéePartielle } =
		décomposeCotisationMaladie(situation)

	return { annuel, mensuel, prorataAnnéePartielle }
}

import { annéeDesRevenus } from './annee-de-simulation'

const MILLISECONDES_PAR_JOUR = 1000 * 60 * 60 * 24

const enUTC = (date: Date): number =>
	Date.UTC(date.getFullYear(), date.getMonth(), date.getDate())

export const joursDansAnnée = (année: number): number =>
	(Date.UTC(année + 1, 0, 1) - Date.UTC(année, 0, 1)) / MILLISECONDES_PAR_JOUR

export const joursAffiliésDansAnnée = (
	dateAffiliation: Date,
	dateFinAffiliation?: Date
): number => {
	const année = annéeDesRevenus(dateAffiliation, dateFinAffiliation)
	const débutAnnée = Date.UTC(année, 0, 1)
	const finAnnée = Date.UTC(année, 11, 31)

	const début = Math.max(enUTC(dateAffiliation), débutAnnée)
	const fin = Math.min(
		dateFinAffiliation ? enUTC(dateFinAffiliation) : finAnnée,
		finAnnée
	)

	return Math.max(0, Math.round((fin - début) / MILLISECONDES_PAR_JOUR) + 1)
}

import { pipe } from 'effect'
import * as O from 'effect/Option'

import { Montant } from '@/domaine/Montant'
import { eurosParAn } from '@/domaine/MontantRecurrent'

import {
	initialSituationFrontalierSuisse,
	SituationFrontalierSuisse,
} from './situation'

type SituationSérialisée = {
	dateAffiliation?: string
	dateFinAffiliation?: string
	salaires?: number
	autresRevenus?: number
}

export const encodeSituation = (
	situation: SituationFrontalierSuisse
): string => {
	const sérialisée: SituationSérialisée = {
		dateAffiliation: pipe(
			situation.dateAffiliation,
			O.map(formatDate),
			O.getOrUndefined
		),
		dateFinAffiliation: pipe(
			situation.dateFinAffiliation,
			O.map(formatDate),
			O.getOrUndefined
		),
		salaires: pipe(
			situation.salaires,
			O.map((montant) => montant.valeur),
			O.getOrUndefined
		),
		autresRevenus: pipe(
			situation.autresRevenus,
			O.map((montant) => montant.valeur),
			O.getOrUndefined
		),
	}

	return toBase64Url(JSON.stringify(sérialisée))
}

export const decodeSituation = (chaîne: string): SituationFrontalierSuisse => {
	const sérialisée = parseSituationSérialisée(chaîne)

	return {
		...initialSituationFrontalierSuisse,
		dateAffiliation: parseDate(sérialisée.dateAffiliation),
		dateFinAffiliation: parseDate(sérialisée.dateFinAffiliation),
		salaires: parseMontant(sérialisée.salaires),
		autresRevenus: parseMontant(sérialisée.autresRevenus),
	}
}

const parseSituationSérialisée = (chaîne: string): SituationSérialisée => {
	try {
		const parsed: unknown = JSON.parse(fromBase64Url(chaîne))

		return typeof parsed === 'object' && parsed !== null
			? (parsed as SituationSérialisée)
			: {}
	} catch {
		return {}
	}
}

const formatDate = (date: Date): string =>
	`${date.getFullYear()}-${String(date.getMonth() + 1).padStart(
		2,
		'0'
	)}-${String(date.getDate()).padStart(2, '0')}`

const parseDate = (valeur: unknown): O.Option<Date> => {
	if (typeof valeur !== 'string') {
		return O.none()
	}
	const composantes = /^(\d{4})-(\d{2})-(\d{2})$/.exec(valeur)
	if (!composantes) {
		return O.none()
	}
	const date = new Date(
		Number(composantes[1]),
		Number(composantes[2]) - 1,
		Number(composantes[3])
	)

	return isNaN(date.getTime()) ? O.none() : O.some(date)
}

const parseMontant = (valeur: unknown): O.Option<Montant<'€/an'>> =>
	typeof valeur === 'number' && Number.isFinite(valeur) && valeur >= 0
		? O.some(eurosParAn(valeur))
		: O.none()

const toBase64Url = (chaîne: string): string =>
	btoa(chaîne).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '')

const fromBase64Url = (chaîne: string): string => {
	const base64 = chaîne.replaceAll('-', '+').replaceAll('_', '/')
	const padding = '='.repeat((4 - (base64.length % 4)) % 4)

	return atob(base64 + padding)
}

import { pipe } from 'effect'
import * as O from 'effect/Option'

import { Montant } from '@/domaine/Montant'
import { Situation } from '@/domaine/Situation'

export interface SituationFrontalierSuisse extends Situation {
	_type: 'frontalier-suisse'
	dateAffiliation: O.Option<Date>
	dateFinAffiliation: O.Option<Date>
	salaires: O.Option<Montant<'€/an'>>
	autresRevenus: O.Option<Montant<'€/an'>>
}

export interface SituationFrontalierSuisseValide extends SituationFrontalierSuisse {
	dateAffiliation: O.Some<Date>
	salaires: O.Some<Montant<'€/an'>>
}

export const initialSituationFrontalierSuisse: SituationFrontalierSuisse = {
	_tag: 'Situation',
	_type: 'frontalier-suisse',
	dateAffiliation: O.none(),
	dateFinAffiliation: O.none(),
	salaires: O.none(),
	autresRevenus: O.none(),
}

export const situationEstCommencée = (
	situation: SituationFrontalierSuisse
): boolean =>
	O.isSome(situation.dateAffiliation) || O.isSome(situation.salaires)

export const datesAffiliationCohérentes = (
	situation: SituationFrontalierSuisse
): boolean =>
	pipe(
		O.zipWith(
			situation.dateAffiliation,
			situation.dateFinAffiliation,
			(début, fin) => début <= fin
		),
		O.getOrElse(() => true)
	)

export const estSituationValide = (
	situation: SituationFrontalierSuisse
): situation is SituationFrontalierSuisseValide =>
	O.isSome(situation.dateAffiliation) &&
	O.isSome(situation.salaires) &&
	datesAffiliationCohérentes(situation)

import { Either } from 'effect'

import { Montant } from '@/domaine/Montant'

import { SituationÉconomieCollaborativeValide } from './situation'

export type RéponseManquante =
	| 'typeDurée'
	| 'autresRevenus'
	| 'classement'
	| 'recettesCourteDurée'

export type TypeAssiette = 'toutes-recettes' | 'recettes-courte-durée'

export interface Assiette {
	type: TypeAssiette
	valeur: Montant<'€/an'>
}

export type RésultatApplicabilité =
	| { applicable: false }
	| { applicable: true; assiette: Assiette }

type RésultatEstApplicable = Either.Either<
	RésultatApplicabilité,
	RéponseManquante[]
>

export const NON_APPLICABLE: RésultatEstApplicable = Either.right({
	applicable: false,
})

export const applicableSurToutesRecettes = (
	valeur: Montant<'€/an'>
): RésultatEstApplicable =>
	Either.right({
		applicable: true,
		assiette: { type: 'toutes-recettes', valeur },
	})

export const applicableSurRecettesCourteDurée = (
	valeur: Montant<'€/an'>
): RésultatEstApplicable =>
	Either.right({
		applicable: true,
		assiette: { type: 'recettes-courte-durée', valeur },
	})

export type EstApplicable = (
	situation: SituationÉconomieCollaborativeValide
) => RésultatEstApplicable

import { Either } from 'effect'

import {
	compareApplicabilitéDesRégimes,
	RésultatApplicabilitéParRégime,
} from './comparateur-régimes'
import { SituationÉconomieCollaborativeValide } from './situation'

export const auMoinsUnRégimePotentiellementApplicable = (
	situation: SituationÉconomieCollaborativeValide
): boolean => {
	const résultats = compareApplicabilitéDesRégimes(situation)

	return résultats.some((résultat: RésultatApplicabilitéParRégime) => {
		const estApplicable =
			Either.isRight(résultat.résultat) && résultat.résultat.right.applicable
		const estSousConditions = Either.isLeft(résultat.résultat)

		return estApplicable || estSousConditions
	})
}

import { Array, Either, pipe } from 'effect'

import { Montant } from '@/domaine/Montant'

import { RéponseManquante, RésultatApplicabilité } from './applicabilité'
import { RégimeInapplicable } from './erreurs'
import {
	calculeCotisationsRégimeGénéral,
	estApplicableRégimeGénéral,
} from './régime-général'
import {
	calculeCotisationsMicroEntreprise,
	estApplicableMicroEntreprise,
} from './régime-micro-entreprise'
import {
	calculeCotisationsSécuritéSocialeDesIndépendants,
	estApplicableSécuritéSocialeDesIndépendants,
} from './régime-sécurité-sociale-indépendants'
import {
	RegimeCotisation,
	SituationÉconomieCollaborativeValide,
} from './situation'

export type RésultatRégimeApplicable = {
	régime: RegimeCotisation
	applicable: true
	cotisations: Montant<'€/an'>
}

export type RésultatRégimeNonApplicable = {
	régime: RegimeCotisation
	applicable: false
	raisonDeNonApplicabilité: RégimeInapplicable
}

type RésultatRégime = RésultatRégimeApplicable | RésultatRégimeNonApplicable

type CalculCotisations = (
	situation: SituationÉconomieCollaborativeValide
) => Either.Either<Montant<'€/an'>, RégimeInapplicable>

export const compareRégimes = (
	situation: SituationÉconomieCollaborativeValide
): RésultatRégime[] =>
	pipe(
		[
			{
				régime: RegimeCotisation.microEntreprise,
				calcul: calculeCotisationsMicroEntreprise as CalculCotisations,
			},
			{
				régime: RegimeCotisation.travailleurIndependant,
				calcul:
					calculeCotisationsSécuritéSocialeDesIndépendants as CalculCotisations,
			},
			{
				régime: RegimeCotisation.regimeGeneral,
				calcul: calculeCotisationsRégimeGénéral as CalculCotisations,
			},
		],
		Array.map(({ régime, calcul }) =>
			Either.match(calcul(situation), {
				onLeft: (erreur) =>
					({
						régime,
						applicable: false,
						raisonDeNonApplicabilité: erreur,
					}) as const,
				onRight: (cotisations) =>
					({
						régime,
						applicable: true,
						cotisations,
					}) as const,
			})
		)
	)

export type RésultatApplicabilitéParRégime = {
	régime: RegimeCotisation
	résultat: Either.Either<RésultatApplicabilité, RéponseManquante[]>
}

export const compareApplicabilitéDesRégimes = (
	situation: SituationÉconomieCollaborativeValide
): RésultatApplicabilitéParRégime[] =>
	pipe(
		[
			{
				régime: RegimeCotisation.microEntreprise,
				estApplicable: estApplicableMicroEntreprise,
			},
			{
				régime: RegimeCotisation.travailleurIndependant,
				estApplicable: estApplicableSécuritéSocialeDesIndépendants,
			},
			{
				régime: RegimeCotisation.regimeGeneral,
				estApplicable: estApplicableRégimeGénéral,
			},
		],
		Array.map(({ régime, estApplicable }) => ({
			régime,
			résultat: estApplicable(situation),
		}))
	)

import { Either } from 'effect'

import { Montant } from '@/domaine/Montant'

import { SimulationImpossible } from './erreurs'
import { calculeCotisationsRégimeGénéral } from './régime-général'
import { calculeCotisationsMicroEntreprise } from './régime-micro-entreprise'
import { calculeCotisationsSécuritéSocialeDesIndépendants } from './régime-sécurité-sociale-indépendants'
import {
	RegimeCotisation,
	SituationÉconomieCollaborativeValide,
} from './situation'

export const DEFAULTS = {
	EST_ALSACE_MOSELLE: false,
	PREMIERE_ANNEE: false,
}

/**
 * Calcule les cotisations sociales pour un régime donné
 * @param situation La situation avec recettes
 * @param régime Le régime de cotisation
 * @returns Un Either contenant soit les cotisations calculées, soit une erreur
 */
export function calculeCotisations(
	situation: SituationÉconomieCollaborativeValide,
	régime: RegimeCotisation
): Either.Either<Montant<'€/an'>, SimulationImpossible> {
	switch (régime) {
		case RegimeCotisation.regimeGeneral:
			return calculeCotisationsRégimeGénéral(situation)
		case RegimeCotisation.microEntreprise:
			return calculeCotisationsMicroEntreprise(situation)
		case RegimeCotisation.travailleurIndependant:
			return calculeCotisationsSécuritéSocialeDesIndépendants(situation)
	}
}

import { Data } from 'effect'

import { Montant } from '@/domaine/Montant'

import { RegimeCotisation, TypeDurée } from './situation'

export type RégimeInapplicable =
	| RecettesInférieuresAuSeuilRequisPourCeRégime
	| RecettesSupérieuresAuPlafondAutoriséPourCeRégime
	| RégimeNonApplicablePourCeTypeDeDurée
	| RégimeNonApplicablePourChambreDHôte
	| AffiliationObligatoire
	| AffiliationNonObligatoire

export class SituationIncomplète extends Data.TaggedError(
	'SituationIncomplète'
)<{
	message: string
}> {
	toString(): string {
		return this.message
	}
}

export type SimulationImpossible = RégimeInapplicable | SituationIncomplète

export class RecettesSupérieuresAuPlafondAutoriséPourCeRégime extends Data.TaggedError(
	'RecettesSupérieuresAuPlafondAutoriséPourCeRégime'
)<{
	recettes: Montant<'€/an'>
	plafond: Montant<'€/an'>
	régime: RegimeCotisation
}> {
	toString(): string {
		return `Recettes (${this.recettes.valeur} €) supérieures au plafond autorisé (${this.plafond.valeur} €). Ce niveau de recettes n'est pas autorisé pour le régime "${this.régime}"`
	}
}

export class RecettesInférieuresAuSeuilRequisPourCeRégime extends Data.TaggedError(
	'RecettesInférieuresAuSeuilRequisPourCeRégime'
)<{
	recettes: Montant<'€/an'>
	seuil: Montant<'€/an'>
	régime: RegimeCotisation
}> {
	toString(): string {
		return `Recettes (${this.recettes.valeur} €) inférieures au seuil de professionnalisation (${this.seuil.valeur} €). Ce niveau de recettes n'est pas autorisé pour le régime "${this.régime}"`
	}
}

export class RégimeNonApplicablePourCeTypeDeDurée extends Data.TaggedError(
	'RégimeNonApplicablePourCeTypeDeDurée'
)<{
	typeDurée: TypeDurée
	régime: RegimeCotisation
	estActivitéPrincipale: boolean
}> {
	toString(): string {
		return `Le régime "${
			this.régime
		}" n'est pas applicable pour le type de durée "${
			this.typeDurée
		}" (activité ${this.estActivitéPrincipale ? 'principale' : 'secondaire'})`
	}
}

export class RégimeNonApplicablePourChambreDHôte extends Data.TaggedError(
	'RégimeNonApplicablePourChambreDHôte'
)<{
	régime: RegimeCotisation
}> {
	toString(): string {
		return `Le régime "${this.régime}" n'est pas applicable pour les chambres d'hôtes`
	}
}

export class AffiliationObligatoire extends Data.TaggedError(
	'AffiliationObligatoire'
)<{
	recettes: Montant<'€/an'>
	seuil: Montant<'€/an'>
}> {
	toString(): string {
		return `L'affiliation est obligatoire au-dessus de ${this.seuil.valeur} € de recettes (recettes : ${this.recettes.valeur} €)`
	}
}

export class AffiliationNonObligatoire extends Data.TaggedError(
	'AffiliationNonObligatoire'
) {
	toString(): string {
		return `L'affiliation n'est pas obligatoire`
	}
}

export const RaisonInapplicabilité = {
	estTypeDeDuréeIncompatible: (
		erreur: RégimeInapplicable
	): erreur is RégimeNonApplicablePourCeTypeDeDurée => {
		return erreur._tag === 'RégimeNonApplicablePourCeTypeDeDurée'
	},

	estChambreDHôte: (
		erreur: RégimeInapplicable
	): erreur is RégimeNonApplicablePourChambreDHôte => {
		return erreur._tag === 'RégimeNonApplicablePourChambreDHôte'
	},

	estRecettesTropÉlevées: (
		erreur: RégimeInapplicable
	): erreur is RecettesSupérieuresAuPlafondAutoriséPourCeRégime => {
		return erreur._tag === 'RecettesSupérieuresAuPlafondAutoriséPourCeRégime'
	},

	estRecettesTropFaibles: (
		erreur: RégimeInapplicable
	): erreur is RecettesInférieuresAuSeuilRequisPourCeRégime => {
		return erreur._tag === 'RecettesInférieuresAuSeuilRequisPourCeRégime'
	},

	estAffiliationObligatoire: (
		erreur: RégimeInapplicable
	): erreur is AffiliationObligatoire => {
		return erreur._tag === 'AffiliationObligatoire'
	},

	estAffiliationNonObligatoire: (
		erreur: RégimeInapplicable
	): erreur is AffiliationNonObligatoire => {
		return erreur._tag === 'AffiliationNonObligatoire'
	},
} as const

import { Either, pipe } from 'effect'

import { PLAFOND_ANNUEL_SECURITE_SOCIALE } from '@/domaine/ConstantesSociales'
import { estPlusGrandOuÉgalÀ, eurosParAn } from '@/domaine/MontantRecurrent'
import { valeurCourante } from '@/domaine/ValeurAnnuelle'

import { AffiliationObligatoire } from './erreurs'
import { SituationÉconomieCollaborativeValide } from './situation'

export const SEUIL_PROFESSIONNALISATION = {
	MEUBLÉ: eurosParAn(23_000),
	CHAMBRE_HÔTE: eurosParAn(
		valeurCourante(PLAFOND_ANNUEL_SECURITE_SOCIALE) * 0.13
	),
} as const

/**
 * Détermine si l'activité est considérée comme professionnelle selon les recettes
 * @param situation La situation avec des recettes ou du revenu net
 * @returns true si les recettes/revenu sont supérieures ou égales au seuil de professionnalisation
 */
export function estActiviteProfessionnelle(
	situation: SituationÉconomieCollaborativeValide
): boolean {
	if (situation.typeHébergement === 'chambre-hôte') {
		return pipe(
			situation.revenuNet.value,
			estPlusGrandOuÉgalÀ(SEUIL_PROFESSIONNALISATION.CHAMBRE_HÔTE)
		)
	}

	return pipe(
		situation.recettes.value,
		estPlusGrandOuÉgalÀ(SEUIL_PROFESSIONNALISATION.MEUBLÉ)
	)
}

/**
 * Vérifie que l'activité n'est pas professionnelle
 * @param situation La situation avec des recettes ou du revenu net
 * @returns `Right(situation)` si l'activité n'est pas professionnelle, `Left(AffiliationObligatoire)` sinon
 */
export function vérifieActivitéNonProfessionnelle(
	situation: SituationÉconomieCollaborativeValide
): Either.Either<SituationÉconomieCollaborativeValide, AffiliationObligatoire> {
	if (!estActiviteProfessionnelle(situation)) {
		return Either.right(situation)
	}

	const { montant, seuil } =
		situation.typeHébergement === 'chambre-hôte'
			? {
					montant: situation.revenuNet.value,
					seuil: SEUIL_PROFESSIONNALISATION.CHAMBRE_HÔTE,
				}
			: {
					montant: situation.recettes.value,
					seuil: SEUIL_PROFESSIONNALISATION.MEUBLÉ,
				}

	return Either.left(
		new AffiliationObligatoire({
			recettes: montant,
			seuil,
		})
	)
}

import { pipe } from 'effect'

import { estPlusGrandOuÉgalÀ } from '@/domaine/MontantRecurrent'

import { SituationMeubléAvecAutresRevenus } from './situation'

export function estActivitéPrincipale(
	situation: SituationMeubléAvecAutresRevenus
): boolean {
	const recettes = situation.recettes.value
	const autresRevenus = situation.autresRevenus.value

	return pipe(recettes, estPlusGrandOuÉgalÀ(autresRevenus))
}

import { Array, Either, pipe } from 'effect'

import { RéponseManquante } from './applicabilité'
import {
	compareApplicabilitéDesRégimes,
	RésultatApplicabilitéParRégime,
} from './comparateur-régimes'
import { SituationÉconomieCollaborativeValide } from './situation'

export const estAffiliationObligatoire = (
	situation: SituationÉconomieCollaborativeValide
): Either.Either<boolean, RéponseManquante[]> => {
	const résultats = compareApplicabilitéDesRégimes(situation)

	const auMoinsUnApplicable = résultats.some(
		(r: RésultatApplicabilitéParRégime) =>
			Either.isRight(r.résultat) && r.résultat.right.applicable
	)

	if (auMoinsUnApplicable) {
		return Either.right(true)
	}

	const aucunApplicable = résultats.every(
		(r: RésultatApplicabilitéParRégime) =>
			Either.isRight(r.résultat) && !r.résultat.right.applicable
	)

	if (aucunApplicable) {
		return Either.right(false)
	}

	return pipe(
		résultats,
		Array.flatMap((r: RésultatApplicabilitéParRégime) =>
			Either.isLeft(r.résultat) ? r.résultat.left : []
		),
		Array.dedupe,
		Either.left
	)
}

export type {
	SituationÉconomieCollaborative,
	SituationÉconomieCollaborativeValide,
	SituationMeubléDeTourisme,
	SituationMeubléDeTourismeValide,
	SituationChambreDHôte,
	SituationChambreDHôteValide,
	RegimeCotisation,
	Classement,
	TypeDurée,
} from './situation'
export { calculeCotisations } from './cotisations'
export { calculeCotisationsRégimeGénéral } from './régime-général'
export { calculeCotisationsMicroEntreprise } from './régime-micro-entreprise'
export { calculeCotisationsSécuritéSocialeDesIndépendants } from './régime-sécurité-sociale-indépendants'
export {
	compareRégimes,
	type RésultatRégimeApplicable,
	type RésultatRégimeNonApplicable,
} from './comparateur-régimes'

import { Either, pipe } from 'effect'

import { Montant } from '@/domaine/Montant'
import { moins } from '@/domaine/MontantRecurrent'

import { calculeCotisations } from './cotisations'
import { SimulationImpossible } from './erreurs'
import {
	RegimeCotisation,
	SituationÉconomieCollaborativeValide,
} from './situation'

/**
 * Calcule le revenu net pour un régime donné
 * @param situation La situation avec des recettes ou revenu net
 * @param régime Le régime de cotisation à utiliser
 * @returns Le revenu net ou une erreur
 */
export const calculeRevenuNet = (
	situation: SituationÉconomieCollaborativeValide,
	régime: RegimeCotisation
): Either.Either<Montant<'€/an'>, SimulationImpossible> => {
	const montantBrut =
		situation.typeHébergement === 'chambre-hôte'
			? situation.revenuNet.value
			: situation.recettes.value

	return pipe(
		calculeCotisations(situation, régime),
		Either.map((cotisations) => pipe(montantBrut, moins(cotisations)))
	)
}

import { Either, Option, pipe } from 'effect'

import { abattement, fois, Montant } from '@/domaine/Montant'
import {
	estPlusGrandOuÉgalÀ,
	estPlusGrandQue,
	eurosParAn,
	moins,
} from '@/domaine/MontantRecurrent'

import {
	applicableSurRecettesCourteDurée,
	applicableSurToutesRecettes,
	EstApplicable,
	NON_APPLICABLE,
} from './applicabilité'
import {
	AffiliationNonObligatoire,
	RecettesSupérieuresAuPlafondAutoriséPourCeRégime,
	RégimeNonApplicablePourCeTypeDeDurée,
	RégimeNonApplicablePourChambreDHôte,
} from './erreurs'
import { estActivitéPrincipale } from './estActivitéPrincipale'
import {
	estActiviteProfessionnelle,
	SEUIL_PROFESSIONNALISATION,
} from './estActiviteProfessionnelle'
import {
	aRenseignéSesAutresRevenus,
	aRenseignéSonTypeDeDurée,
	faitDeLaLocationCourteEtLongueDurée,
	RegimeCotisation,
	SituationÉconomieCollaborativeValide,
	situationParDéfaut,
} from './situation'

export const PLAFOND_REGIME_GENERAL = eurosParAn(77_700)
export const TAUX_COTISATION_RG_NORMAL = 0.4742
export const TAUX_COTISATION_RG_ALSACE_MOSELLE = 0.4872
export const ABATTEMENT_REGIME_GENERAL = 0.6

/**
 * Calcule les cotisations sociales pour le régime général
 * @param situation La situation avec des recettes
 * @returns Un Either contenant soit les cotisations calculées, soit une erreur
 */
export function calculeCotisationsRégimeGénéral(
	situation: SituationÉconomieCollaborativeValide
): Either.Either<
	Montant<'€/an'>,
	| AffiliationNonObligatoire
	| RecettesSupérieuresAuPlafondAutoriséPourCeRégime
	| RégimeNonApplicablePourChambreDHôte
	| RégimeNonApplicablePourCeTypeDeDurée
> {
	if (situation.typeHébergement === 'chambre-hôte') {
		return Either.left(
			new RégimeNonApplicablePourChambreDHôte({
				régime: RegimeCotisation.regimeGeneral,
			})
		)
	}

	const recettes = situation.recettes.value

	if (pipe(recettes, estPlusGrandQue(PLAFOND_REGIME_GENERAL))) {
		return Either.left(
			new RecettesSupérieuresAuPlafondAutoriséPourCeRégime({
				recettes,
				plafond: PLAFOND_REGIME_GENERAL,
				régime: RegimeCotisation.regimeGeneral,
			})
		)
	}

	const applicabilité = estApplicableRégimeGénéral(situation)
	if (Either.isRight(applicabilité) && !applicabilité.right.applicable) {
		return Either.left(new AffiliationNonObligatoire())
	}

	const estAlsaceMoselle = Option.getOrElse(
		situation.estAlsaceMoselle,
		() => situationParDéfaut.estAlsaceMoselle
	)

	const premièreAnnée = Option.getOrElse(
		situation.premièreAnnée,
		() => situationParDéfaut.premièreAnnée
	)

	const assiette = premièreAnnée
		? pipe(recettes, estPlusGrandQue(SEUIL_PROFESSIONNALISATION.MEUBLÉ))
			? pipe(recettes, moins(SEUIL_PROFESSIONNALISATION.MEUBLÉ))
			: eurosParAn(0)
		: recettes

	const taux = estAlsaceMoselle
		? TAUX_COTISATION_RG_ALSACE_MOSELLE
		: TAUX_COTISATION_RG_NORMAL

	const cotisations = pipe(
		assiette,
		abattement(ABATTEMENT_REGIME_GENERAL),
		fois(taux)
	)

	return Either.right(cotisations)
}

export const estApplicableRégimeGénéral: EstApplicable = (situation) => {
	if (situation.typeHébergement === 'chambre-hôte') {
		return NON_APPLICABLE
	}

	const recettes = situation.recettes.value

	if (pipe(recettes, estPlusGrandQue(PLAFOND_REGIME_GENERAL))) {
		return NON_APPLICABLE
	}

	if (!estActiviteProfessionnelle(situation)) {
		return NON_APPLICABLE
	}

	if (!aRenseignéSesAutresRevenus(situation)) {
		return Either.left(['autresRevenus'])
	}

	if (!estActivitéPrincipale(situation)) {
		if (!aRenseignéSonTypeDeDurée(situation)) {
			return Either.left(['typeDurée'])
		}
		const typeDurée = situation.typeDurée.value

		if (faitDeLaLocationCourteEtLongueDurée(situation)) {
			if (Option.isNone(situation.recettesCourteDurée)) {
				return Either.left(['recettesCourteDurée'])
			}
			const recettesCourteDurée = situation.recettesCourteDurée.value
			if (
				!pipe(
					recettesCourteDurée,
					estPlusGrandOuÉgalÀ(SEUIL_PROFESSIONNALISATION.MEUBLÉ)
				)
			) {
				return NON_APPLICABLE
			}

			return applicableSurRecettesCourteDurée(recettesCourteDurée)
		} else if (typeDurée !== 'courte') {
			return NON_APPLICABLE
		}
	}

	if (pipe(recettes, estPlusGrandOuÉgalÀ(SEUIL_PROFESSIONNALISATION.MEUBLÉ))) {
		if (!aRenseignéSonTypeDeDurée(situation)) {
			return Either.left(['typeDurée'])
		}
		const typeDurée = situation.typeDurée.value

		if (estActivitéPrincipale(situation) && typeDurée !== 'courte') {
			return NON_APPLICABLE
		}
	}

	return applicableSurToutesRecettes(recettes)
}

import { Either, Option, pipe } from 'effect'

import { evalueAvecPublicodes } from '@/domaine/engine/engineSingleton'
import { Montant } from '@/domaine/Montant'
import {
	estPlusGrandOuÉgalÀ,
	estPlusGrandQue,
	eurosParAn,
} from '@/domaine/MontantRecurrent'
import {
	AutoEntrepreneurChiffreAffaireDansPublicodes,
	AutoEntrepreneurContexteDansPublicodes,
	AutoEntrepreneurCotisationsEtContributionsDansPublicodes,
} from '@/domaine/publicodes/AutoEntrepreneurContexteDansPublicodes'

import {
	applicableSurRecettesCourteDurée,
	applicableSurToutesRecettes,
	EstApplicable,
	NON_APPLICABLE,
} from './applicabilité'
import {
	AffiliationNonObligatoire,
	AffiliationObligatoire,
	RecettesSupérieuresAuPlafondAutoriséPourCeRégime,
	RégimeNonApplicablePourCeTypeDeDurée,
	RégimeNonApplicablePourChambreDHôte,
} from './erreurs'
import { estActivitéPrincipale } from './estActivitéPrincipale'
import {
	estActiviteProfessionnelle,
	SEUIL_PROFESSIONNALISATION,
} from './estActiviteProfessionnelle'
import {
	aRenseignéSesAutresRevenus,
	aRenseignéSonClassement,
	aRenseignéSonTypeDeDurée,
	faitDeLaLocationCourteEtLongueDurée,
	RegimeCotisation,
	SituationÉconomieCollaborativeValide,
	situationParDéfaut,
} from './situation'

export const PLAFOND_MICRO_ENTREPRISE_NON_CLASSE = eurosParAn(77_700)
export const PLAFOND_MICRO_ENTREPRISE_TOURISME_CLASSE = eurosParAn(188_700)
export const PLAFOND_MICRO_ENTREPRISE_CHAMBRE_HOTE = eurosParAn(188_700)

/**
 * Calcule les cotisations sociales pour le régime micro-entreprise
 * @param situation La situation avec des recettes
 * @returns Un Either contenant soit les cotisations calculées, soit une erreur
 */
export function calculeCotisationsMicroEntreprise(
	situation: SituationÉconomieCollaborativeValide
): Either.Either<
	Montant<'€/an'>,
	| AffiliationNonObligatoire
	| AffiliationObligatoire
	| RecettesSupérieuresAuPlafondAutoriséPourCeRégime
	| RégimeNonApplicablePourCeTypeDeDurée
	| RégimeNonApplicablePourChambreDHôte
> {
	const applicabilité = estApplicableMicroEntreprise(situation)
	if (Either.isRight(applicabilité) && !applicabilité.right.applicable) {
		return Either.left(new AffiliationNonObligatoire())
	}

	if (situation.typeHébergement === 'chambre-hôte') {
		const revenuNet = situation.revenuNet.value

		if (
			pipe(revenuNet, estPlusGrandQue(PLAFOND_MICRO_ENTREPRISE_CHAMBRE_HOTE))
		) {
			return Either.left(
				new RecettesSupérieuresAuPlafondAutoriséPourCeRégime({
					recettes: revenuNet,
					plafond: PLAFOND_MICRO_ENTREPRISE_CHAMBRE_HOTE,
					régime: RegimeCotisation.microEntreprise,
				})
			)
		}

		const cotisations = evalueAvecPublicodes<number>(
			{
				...AutoEntrepreneurContexteDansPublicodes,
				...AutoEntrepreneurChiffreAffaireDansPublicodes.fromMontant(revenuNet),
			},
			AutoEntrepreneurCotisationsEtContributionsDansPublicodes.enEurosParAn
		)

		return Either.right(eurosParAn(cotisations))
	}

	const recettes = situation.recettes.value

	const classement = Option.getOrElse(
		situation.classement,
		() => situationParDéfaut.classement
	)

	const plafond =
		classement === 'non-classé'
			? PLAFOND_MICRO_ENTREPRISE_NON_CLASSE
			: PLAFOND_MICRO_ENTREPRISE_TOURISME_CLASSE

	if (pipe(recettes, estPlusGrandQue(plafond))) {
		return Either.left(
			new RecettesSupérieuresAuPlafondAutoriséPourCeRégime({
				recettes,
				plafond,
				régime: RegimeCotisation.microEntreprise,
			})
		)
	}

	const cotisations = evalueAvecPublicodes<number>(
		{
			...AutoEntrepreneurContexteDansPublicodes,
			...AutoEntrepreneurChiffreAffaireDansPublicodes.fromMontant(recettes),
		},
		AutoEntrepreneurCotisationsEtContributionsDansPublicodes.enEurosParAn
	)

	return Either.right(eurosParAn(cotisations))
}

export const estApplicableMicroEntreprise: EstApplicable = (situation) => {
	if (!estActiviteProfessionnelle(situation)) {
		return NON_APPLICABLE
	}

	if (situation.typeHébergement === 'chambre-hôte') {
		return applicableSurToutesRecettes(situation.revenuNet.value)
	}

	const recettes = situation.recettes.value

	if (!aRenseignéSesAutresRevenus(situation)) {
		return Either.left(['autresRevenus'])
	}

	if (!aRenseignéSonTypeDeDurée(situation)) {
		return Either.left(['typeDurée'])
	}
	const typeDurée = situation.typeDurée.value

	if (typeDurée === 'longue') {
		if (!estActivitéPrincipale(situation)) {
			return NON_APPLICABLE
		}

		return applicableSurToutesRecettes(recettes)
	}

	if (
		!estActivitéPrincipale(situation) &&
		faitDeLaLocationCourteEtLongueDurée(situation)
	) {
		if (Option.isNone(situation.recettesCourteDurée)) {
			return Either.left(['recettesCourteDurée'])
		}
		const recettesCourteDurée = situation.recettesCourteDurée.value
		if (
			!pipe(
				recettesCourteDurée,
				estPlusGrandOuÉgalÀ(SEUIL_PROFESSIONNALISATION.MEUBLÉ)
			)
		) {
			return NON_APPLICABLE
		}

		if (!aRenseignéSonClassement(situation)) {
			return Either.left(['classement'])
		}
		if (situation.classement.value !== 'classé') {
			return NON_APPLICABLE
		}

		return applicableSurRecettesCourteDurée(recettesCourteDurée)
	}

	if (!aRenseignéSonClassement(situation)) {
		return Either.left(['classement'])
	}
	const classement = situation.classement.value

	if (!estActivitéPrincipale(situation) && classement !== 'classé') {
		return NON_APPLICABLE
	}

	if (classement !== 'classé') {
		return NON_APPLICABLE
	}

	return applicableSurToutesRecettes(recettes)
}

import { Either, Option, pipe } from 'effect'

import { evalueAvecPublicodes } from '@/domaine/engine/engineSingleton'
import { Montant } from '@/domaine/Montant'
import { estPlusGrandOuÉgalÀ, eurosParAn } from '@/domaine/MontantRecurrent'
import {
	TravailleurIndependantChiffreAffaireDansPublicodes,
	TravailleurIndependantContexteDansPublicodes,
	TravailleurIndependantCotisationsEtContributionsDansPublicodes,
} from '@/domaine/publicodes/TravailleurIndependantContexteDansPublicodes'

import {
	applicableSurRecettesCourteDurée,
	applicableSurToutesRecettes,
	EstApplicable,
	NON_APPLICABLE,
} from './applicabilité'
import { AffiliationNonObligatoire } from './erreurs'
import { estActivitéPrincipale } from './estActivitéPrincipale'
import {
	estActiviteProfessionnelle,
	SEUIL_PROFESSIONNALISATION,
} from './estActiviteProfessionnelle'
import {
	aRenseignéSesAutresRevenus,
	aRenseignéSonTypeDeDurée,
	faitDeLaLocationCourteEtLongueDurée,
	SituationÉconomieCollaborativeValide,
} from './situation'

export const estApplicableSécuritéSocialeDesIndépendants: EstApplicable = (
	situation
) => {
	if (!estActiviteProfessionnelle(situation)) {
		return NON_APPLICABLE
	}

	if (situation.typeHébergement === 'chambre-hôte') {
		return applicableSurToutesRecettes(situation.revenuNet.value)
	}

	const recettes = situation.recettes.value

	if (!aRenseignéSesAutresRevenus(situation)) {
		return Either.left(['autresRevenus'])
	}

	if (!estActivitéPrincipale(situation)) {
		if (!aRenseignéSonTypeDeDurée(situation)) {
			return Either.left(['typeDurée'])
		}

		if (faitDeLaLocationCourteEtLongueDurée(situation)) {
			if (Option.isNone(situation.recettesCourteDurée)) {
				return Either.left(['recettesCourteDurée'])
			}
			const recettesCourteDurée = situation.recettesCourteDurée.value
			if (
				!pipe(
					recettesCourteDurée,
					estPlusGrandOuÉgalÀ(SEUIL_PROFESSIONNALISATION.MEUBLÉ)
				)
			) {
				return NON_APPLICABLE
			}

			return applicableSurRecettesCourteDurée(recettesCourteDurée)
		} else if (situation.typeDurée.value !== 'courte') {
			return NON_APPLICABLE
		}
	}

	return applicableSurToutesRecettes(recettes)
}

/**
 * Calcule les cotisations sociales pour le régime Sécurité Sociale des Indépendants
 * Ce régime est toujours applicable, quel que soit le montant des recettes/revenu net,
 * sauf en cas d'activité secondaire où l'affiliation n'est pas obligatoire
 * C'est le régime "par défaut" quand les autres plafonds sont dépassés
 * @param situation La situation avec des recettes ou revenu net obligatoirement définis
 * @returns Un Either contenant soit les cotisations calculées, soit une erreur
 */
export function calculeCotisationsSécuritéSocialeDesIndépendants(
	situation: SituationÉconomieCollaborativeValide
): Either.Either<Montant<'€/an'>, AffiliationNonObligatoire> {
	const applicabilité = estApplicableSécuritéSocialeDesIndépendants(situation)
	if (Either.isRight(applicabilité) && !applicabilité.right.applicable) {
		return Either.left(new AffiliationNonObligatoire())
	}

	if (situation.typeHébergement === 'chambre-hôte') {
		const revenuNet = situation.revenuNet.value

		const cotisations = evalueAvecPublicodes<number>(
			{
				...TravailleurIndependantContexteDansPublicodes,
				...TravailleurIndependantChiffreAffaireDansPublicodes.fromMontant(
					revenuNet
				),
			},
			TravailleurIndependantCotisationsEtContributionsDansPublicodes.enEurosParAn
		)

		return Either.right(eurosParAn(cotisations))
	}

	const cotisations = evalueAvecPublicodes<number>(
		{
			...TravailleurIndependantContexteDansPublicodes,
			...TravailleurIndependantChiffreAffaireDansPublicodes.fromMontant(
				situation.recettes.value
			),
		},
		TravailleurIndependantCotisationsEtContributionsDansPublicodes.enEurosParAn
	)

	return Either.right(eurosParAn(cotisations))
}

import * as O from 'effect/Option'

import { Montant } from '@/domaine/Montant'
import { eurosParAn } from '@/domaine/MontantRecurrent'
import { Situation } from '@/domaine/Situation'

interface SituationÉconomieCollaborativeBase extends Situation {
	_type: 'économie-collaborative'
	estAlsaceMoselle: O.Option<boolean>
	premièreAnnée: O.Option<boolean>
}

export interface SituationChambreDHôte extends SituationÉconomieCollaborativeBase {
	typeHébergement: 'chambre-hôte'
	revenuNet: O.Option<Montant<'€/an'>>
}

interface SituationMeubléDeTourismeBase extends SituationÉconomieCollaborativeBase {
	typeHébergement: 'meublé-tourisme'
	recettes: O.Option<Montant<'€/an'>>
	autresRevenus: O.Option<Montant<'€/an'>>
	classement: O.Option<Classement>
}

export interface SituationMeubléLongueDurée extends SituationMeubléDeTourismeBase {
	typeDurée: O.Some<'longue'>
}

export interface SituationMeubléCourteDurée extends SituationMeubléDeTourismeBase {
	typeDurée: O.Some<'courte'>
}

export interface SituationMeubléDuréeMixte extends SituationMeubléDeTourismeBase {
	typeDurée: O.Some<'mixte'>
	recettesCourteDurée: O.Option<Montant<'€/an'>>
}

export interface SituationMeubléDeTourismeIncomplète extends SituationMeubléDeTourismeBase {
	typeDurée: O.None<TypeDurée>
}

export type SituationMeubléDeTourisme =
	| SituationMeubléLongueDurée
	| SituationMeubléCourteDurée
	| SituationMeubléDuréeMixte
	| SituationMeubléDeTourismeIncomplète

export type SituationÉconomieCollaborative =
	| SituationChambreDHôte
	| SituationMeubléDeTourisme

export type Classement = 'classé' | 'non-classé' | 'mixte'

export type TypeDurée = 'courte' | 'longue' | 'mixte'

export type TypeHébergement = 'meublé-tourisme' | 'chambre-hôte'

export const situationParDéfaut = {
	autresRevenus: eurosParAn(0),
	classement: 'non-classé' as Classement,
	estAlsaceMoselle: false,
	premièreAnnée: false,
}

export enum RegimeCotisation {
	microEntreprise = 'micro-entreprise',
	travailleurIndependant = 'travailleur-indépendant',
	regimeGeneral = 'régime-général',
}

export const initialSituationMeubléDeTourisme: SituationMeubléDeTourismeIncomplète =
	{
		_tag: 'Situation',
		_type: 'économie-collaborative',
		typeHébergement: 'meublé-tourisme',
		recettes: O.none(),
		autresRevenus: O.none(),
		typeDurée: O.none() as O.None<TypeDurée>,
		classement: O.none(),
		estAlsaceMoselle: O.none(),
		premièreAnnée: O.none(),
	}

export const initialSituationChambreDHôte: SituationChambreDHôte = {
	_tag: 'Situation',
	_type: 'économie-collaborative',
	typeHébergement: 'chambre-hôte',
	revenuNet: O.none(),
	estAlsaceMoselle: O.none(),
	premièreAnnée: O.none(),
}

export const initialSituationÉconomieCollaborative: SituationÉconomieCollaborative =
	initialSituationMeubléDeTourisme

export interface SituationMeubléLongueDuréeValide extends SituationMeubléLongueDurée {
	recettes: O.Some<Montant<'€/an'>>
}

export interface SituationMeubléCourteDuréeValide extends SituationMeubléCourteDurée {
	recettes: O.Some<Montant<'€/an'>>
}

export interface SituationMeubléDuréeMixteValide extends SituationMeubléDuréeMixte {
	recettes: O.Some<Montant<'€/an'>>
	recettesCourteDurée: O.Some<Montant<'€/an'>>
}

export interface SituationMeubléDeTourismeIncomplèteValide extends SituationMeubléDeTourismeIncomplète {
	recettes: O.Some<Montant<'€/an'>>
}

export type SituationMeubléDeTourismeValide =
	| SituationMeubléLongueDuréeValide
	| SituationMeubléCourteDuréeValide
	| SituationMeubléDuréeMixteValide
	| SituationMeubléDeTourismeIncomplèteValide

export type SituationMeubléAvecAutresRevenus =
	SituationMeubléDeTourismeValide & {
		autresRevenus: O.Some<Montant<'€/an'>>
	}

export function aRenseignéSesAutresRevenus(
	situation: SituationMeubléDeTourismeValide
): situation is SituationMeubléAvecAutresRevenus {
	return O.isSome(situation.autresRevenus)
}

export type SituationMeubléAvecTypeDurée = SituationMeubléDeTourismeValide & {
	typeDurée: O.Some<TypeDurée>
}

export function aRenseignéSonTypeDeDurée(
	situation: SituationMeubléDeTourismeValide
): situation is SituationMeubléAvecTypeDurée {
	return O.isSome(situation.typeDurée)
}

export type SituationMeubléAvecClassement = SituationMeubléDeTourismeValide & {
	classement: O.Some<Classement>
}

export function aRenseignéSonClassement(
	situation: SituationMeubléDeTourismeValide
): situation is SituationMeubléAvecClassement {
	return O.isSome(situation.classement)
}

export interface SituationChambreDHôteValide extends SituationChambreDHôte {
	revenuNet: O.Some<Montant<'€/an'>>
}

export type SituationÉconomieCollaborativeValide =
	| SituationMeubléDeTourismeValide
	| SituationChambreDHôteValide

export function estSituationMeubléDeTourismeValide(
	situation: SituationÉconomieCollaborative
): situation is SituationMeubléDeTourismeValide {
	return (
		situation.typeHébergement === 'meublé-tourisme' &&
		O.isSome(situation.recettes)
	)
}

export function estSituationChambreDHôteValide(
	situation: SituationÉconomieCollaborative
): situation is SituationChambreDHôteValide {
	return (
		situation.typeHébergement === 'chambre-hôte' &&
		O.isSome(situation.revenuNet)
	)
}

export function estSituationValide(
	situation: SituationÉconomieCollaborative
): situation is SituationÉconomieCollaborativeValide {
	return (
		estSituationMeubléDeTourismeValide(situation) ||
		estSituationChambreDHôteValide(situation)
	)
}

export const simulationEstCommencée = (
	situation?: SituationÉconomieCollaborative
) => !!situation && estSituationValide(situation)

export function faitDeLaLocationCourteDurée(
	situation: SituationMeubléDeTourismeValide
): situation is
	| SituationMeubléCourteDuréeValide
	| SituationMeubléDuréeMixteValide {
	return O.match(situation.typeDurée, {
		onNone: () => false,
		onSome: (typeDurée) => typeDurée === 'courte' || typeDurée === 'mixte',
	})
}

export function faitDeLaLocationCourteEtLongueDurée(
	situation: SituationMeubléDeTourismeValide
): situation is SituationMeubléDuréeMixteValide {
	return O.match(situation.typeDurée, {
		onNone: () => false,
		onSome: (typeDurée) => typeDurée === 'mixte',
	})
}

export function faitDeLaLocationLongueDuréeExclusivement(
	situation: SituationMeubléDeTourismeValide
): situation is SituationMeubléLongueDuréeValide {
	return O.match(situation.typeDurée, {
		onNone: () => false,
		onSome: (typeDurée) => typeDurée === 'longue',
	})
}

export function faitDeLaLocationCourteDuréeExclusivement(
	situation: SituationMeubléDeTourismeValide
): situation is SituationMeubléCourteDuréeValide {
	return O.match(situation.typeDurée, {
		onNone: () => false,
		onSome: (typeDurée) => typeDurée === 'courte',
	})
}

export function setTypeDurée(
	typeDurée: O.Option<TypeDurée>
): (situation: SituationMeubléDeTourisme) => SituationMeubléDeTourisme {
	return (situation) => {
		return O.match(typeDurée, {
			onNone: () =>
				({
					...situation,
					typeDurée: O.none() as O.None<TypeDurée>,
				}) as SituationMeubléDeTourismeIncomplète,
			onSome: (durée) => {
				if (durée === 'longue') {
					const { recettesCourteDurée, ...rest } =
						situation as SituationMeubléDeTourisme & {
							recettesCourteDurée?: O.Option<Montant<'€/an'>>
						}

					return {
						...rest,
						typeDurée: O.some(durée),
					} as SituationMeubléLongueDurée
				}

				if (durée === 'courte') {
					const { recettesCourteDurée, ...rest } =
						situation as SituationMeubléDeTourisme & {
							recettesCourteDurée?: O.Option<Montant<'€/an'>>
						}

					return {
						...rest,
						typeDurée: O.some(durée),
					} as SituationMeubléCourteDurée
				}

				return {
					...situation,
					typeDurée: O.some(durée),
					recettesCourteDurée:
						'recettesCourteDurée' in situation
							? situation.recettesCourteDurée
							: O.none(),
				} as SituationMeubléDuréeMixte
			},
		})
	}
}

import * as O from 'effect/Option'

import { Montant } from '@/domaine/Montant'
import { eurosParAn } from '@/domaine/MontantRecurrent'

import {
	Classement,
	SituationChambreDHôteValide,
	SituationMeubléDeTourismeValide,
	TypeDurée,
} from '../situation'

type SituationBuilderState = {
	recettes?: number
	recettesCourteDurée?: number
	autresRevenus?: number
	typeDurée?: TypeDurée
	classement?: Classement
	estAlsaceMoselle?: boolean
	premièreAnnée?: boolean
}

type SituationBuilderApi = {
	avecRecettes: (recettes: number) => SituationBuilderApi
	avecRecettesCourteDurée: (recettesCourteDurée: number) => SituationBuilderApi
	avecAutresRevenus: (autresRevenus: number) => SituationBuilderApi
	avecTypeDurée: (typeDurée: TypeDurée) => SituationBuilderApi
	avecClassement: (classement: Classement) => SituationBuilderApi
	avecAlsaceMoselle: (estAlsaceMoselle?: boolean) => SituationBuilderApi
	avecPremièreAnnée: (premièreAnnée?: boolean) => SituationBuilderApi
	build: () => SituationMeubléDeTourismeValide
}

export function situationMeubléDeTourismeBuilder(
	state: SituationBuilderState = {}
): SituationBuilderApi {
	return {
		avecRecettes: (recettes) =>
			situationMeubléDeTourismeBuilder({ ...state, recettes }),
		avecRecettesCourteDurée: (recettesCourteDurée) =>
			situationMeubléDeTourismeBuilder({
				...state,
				recettesCourteDurée,
				typeDurée: state.typeDurée === 'longue' ? 'mixte' : state.typeDurée,
			}),
		avecAutresRevenus: (autresRevenus) =>
			situationMeubléDeTourismeBuilder({ ...state, autresRevenus }),
		avecTypeDurée: (typeDurée) =>
			situationMeubléDeTourismeBuilder(
				typeDurée === 'longue'
					? { ...state, typeDurée, recettesCourteDurée: undefined }
					: { ...state, typeDurée }
			),
		avecClassement: (classement) =>
			situationMeubléDeTourismeBuilder({ ...state, classement }),
		avecAlsaceMoselle: (estAlsaceMoselle = true) =>
			situationMeubléDeTourismeBuilder({ ...state, estAlsaceMoselle }),
		avecPremièreAnnée: (premièreAnnée = true) =>
			situationMeubléDeTourismeBuilder({ ...state, premièreAnnée }),
		build: () => {
			if (state.recettes === undefined) {
				throw new Error(
					'Les recettes sont obligatoires pour construire une situation valide'
				)
			}

			const baseSituation = {
				_tag: 'Situation' as const,
				_type: 'économie-collaborative' as const,
				typeHébergement: 'meublé-tourisme' as const,
				recettes: O.some(eurosParAn(state.recettes)) as O.Some<Montant<'€/an'>>,
				autresRevenus: O.fromNullable(state.autresRevenus).pipe(
					O.map(eurosParAn)
				),
				classement: O.fromNullable(state.classement),
				estAlsaceMoselle: O.fromNullable(state.estAlsaceMoselle),
				premièreAnnée: O.fromNullable(state.premièreAnnée),
			}

			if (state.typeDurée === 'longue') {
				return {
					...baseSituation,
					typeDurée: O.some(state.typeDurée),
				} as SituationMeubléDeTourismeValide
			}

			if (state.typeDurée === 'courte' || state.typeDurée === 'mixte') {
				return {
					...baseSituation,
					typeDurée: O.some(state.typeDurée),
					recettesCourteDurée: O.fromNullable(state.recettesCourteDurée).pipe(
						O.map(eurosParAn)
					),
				} as SituationMeubléDeTourismeValide
			}

			return {
				...baseSituation,
				typeDurée: O.none() as O.None<TypeDurée>,
			} as SituationMeubléDeTourismeValide
		},
	}
}

type SituationChambreDHôteBuilderState = {
	revenuNet?: number
}

type SituationChambreDHôteBuilderApi = {
	avecRevenuNet: (revenuNet: number) => SituationChambreDHôteBuilderApi
	build: () => SituationChambreDHôteValide
}

export function situationChambreDHôteBuilder(
	state: SituationChambreDHôteBuilderState = {}
): SituationChambreDHôteBuilderApi {
	return {
		avecRevenuNet: (revenuNet) =>
			situationChambreDHôteBuilder({ ...state, revenuNet }),
		build: () => {
			if (state.revenuNet === undefined) {
				throw new Error(
					"Le revenu net est obligatoire pour construire une situation chambre d'hôte valide"
				)
			}

			return {
				_tag: 'Situation',
				_type: 'économie-collaborative',
				typeHébergement: 'chambre-hôte',
				revenuNet: O.some(eurosParAn(state.revenuNet)) as O.Some<
					Montant<'€/an'>
				>,
				estAlsaceMoselle: O.none(),
				premièreAnnée: O.none(),
			}
		},
	}
}

export interface Adresse {
	complète?: string
	codeCommune: string
}

import { Contexte } from '@/domaine/Contexte'

export const AssimiléSalariéContexte: Contexte = {
	'entreprise . imposition': "'IS'",
	'entreprise . catégorie juridique': "'SAS'",
	'entreprise . associés': "'unique'",
}

export type Brand<T, U extends string> = T & { __tag: U }

import { Brand } from '@/domaine/Brand'

export type CodeActivite = Brand<string, 'CodeActivite'>
// Pourrait être inféré des données de fetchBénéfice

export const codeActivité = (code: string) => code as CodeActivite

import { Brand } from '@/domaine/Brand'

export type CodeCatégorieJuridique = Brand<string, 'CodeCatégorieJuridique'>

export const codeCatégorieJuridique = (code: string) =>
	code as CodeCatégorieJuridique

import { NonEmptyReadonlyArray } from 'effect/Array'

import { Contexte } from '@/domaine/Contexte'
import { PublicodesSimulationConfig } from '@/domaine/PublicodesSimulationConfig'

export interface ComparateurConfig extends PublicodesSimulationConfig {
	contextes: NonEmptyReadonlyArray<Contexte>
}

export const isComparateurConfig = (
	config: PublicodesSimulationConfig
): config is ComparateurConfig => 'contextes' in config

import { ValeurAnnuelle } from './ValeurAnnuelle'

/**
 * @mise-à-jour-annuelle
 * Plafond Annuel de la Sécurité Sociale (PASS)
 * Source : https://www.urssaf.fr/accueil/outils-documentation/taux-baremes/plafonds-securite-sociale.html
 */
export const PLAFOND_ANNUEL_SECURITE_SOCIALE: ValeurAnnuelle<number> = {
	2018: 39_732,
	2024: 46_368,
	2025: 47_100,
	2026: 48_060,
} as const

import { SituationPublicodes } from '@/domaine/SituationPublicodes'

export type Contexte = SituationPublicodes

import { format, formatISOWithOptions, parse } from 'date-fns/fp'
import { pipe } from 'effect'
import { isString } from 'effect/String'

export type PublicodeDate =
	`${number}${number}/${number}${number}/${number}${number}${number}${number}`

const publicodesStandardDateFormat = 'dd/MM/yyyy'
const publicodesStandardDateRegex = /^\d{2}\/\d{2}\/\d{4}$/

export const isPublicodesStandardDate = (
	date: unknown
): date is PublicodeDate =>
	isString(date) && publicodesStandardDateRegex.test(date)

/**
 * @example 2024-12-31
 */
export type IsoDate =
	`${number}${number}${number}${number}-${number}${number}-${number}${number}`

const isoDateFormat = 'yyyy-MM-dd'
const isoDateRegex = /^\d{4}-\d{2}-\d{2}$/

export const isIsoDate = (date: unknown): date is IsoDate =>
	isString(date) && isoDateRegex.test(date)

type DateToPublicodeDate = (d: Date) => PublicodeDate

export const toPublicodeDate = format(
	publicodesStandardDateFormat
) as DateToPublicodeDate

type PublicodeDateToDate = (d: PublicodeDate) => Date

export const parsePublicodesDateString = parse(
	new Date(),
	publicodesStandardDateFormat
) as PublicodeDateToDate

export const parseIsoDateString = parse(new Date(), isoDateFormat)

export const dateToIsoDate = (date: Date): IsoDate =>
	formatISOWithOptions({ representation: 'date' }, date) as IsoDate

export const publicodesDateToIsoDate = (date: PublicodeDate): IsoDate =>
	pipe(date, parsePublicodesDateString, dateToIsoDate)

export const isoDateToPublicodesDate = (date: IsoDate): PublicodeDate =>
	pipe(date, parseIsoDateString, toPublicodeDate)

import { CodeActivite } from '@/domaine/CodeActivite'
import { CodeCatégorieJuridique } from '@/domaine/CodeCatégorieJuridique'
import { Établissement } from '@/domaine/Établissement'
import { DottedName } from '@/domaine/publicodes/DottedName'
import { Siren } from '@/domaine/Siren'

export interface Entreprise {
	nom: string
	siren: Siren
	dateDeCréation: Date
	codeCatégorieJuridique: CodeCatégorieJuridique
	activitéPrincipale: CodeActivite
	siège?: Établissement
	établissement: Établissement
}

export const RÈGLES_IDENTITÉ_ENTREPRISE = [
	'entreprise . date de création',
	'entreprise . code catégorie juridique',
	'entreprise . catégorie juridique',
	'entreprise . SIREN',
	'entreprise . nom',
	'établissement . SIRET',
] as const satisfies ReadonlyArray<DottedName>

export type RègleIdentitéEntreprise =
	(typeof RÈGLES_IDENTITÉ_ENTREPRISE)[number]

const établissementEstLeSiège = (entreprise: Entreprise): boolean =>
	!!entreprise.siège &&
	!!entreprise.siège.adresse.complète &&
	entreprise.siège.adresse.complète ===
		entreprise.établissement.adresse.complète

export const établissementEstDifférentDuSiège = (
	entreprise: Entreprise
): boolean => !établissementEstLeSiège(entreprise)

import { Entreprise } from './Entreprise'

export interface EntreprisesRepository {
	rechercheTexteLibre: (
		termeDeRecherche: string
	) => Promise<Array<Entreprise> | null>
}

export type EnvironnementDéployé = 'développement' | 'staging' | 'production'

export const isExpressionAvecUnité = (
	value: unknown
): value is { valeur: number; unité: string } => {
	if (typeof value !== 'object' || value === null) return false
	const v = value as Record<string, unknown>

	return typeof v.valeur === 'number' && typeof v.unité === 'string'
}

import { Contexte } from '@/domaine/Contexte'

export const IndépendantContexte: Contexte = {
	'entreprise . catégorie juridique': "'EI'",
	'entreprise . catégorie juridique . EI . auto-entrepreneur': 'non',
}

import { Data, Either } from 'effect'
import { dual } from 'effect/Function'
import { isObject } from 'effect/Predicate'

import { UnitéMonétaire } from './Unites'

export interface Montant<T extends UnitéMonétaire = UnitéMonétaire> {
	readonly _tag: 'Montant'
	readonly valeur: number
	readonly unité: T
}

export const isMontant = (something: unknown): something is Montant =>
	isObject(something) && '_tag' in something && something._tag === 'Montant'

const makeMontant = Data.tagged<Montant>('Montant')

export class DivisionParZéro extends Data.TaggedError('DivisionParZéro') {}

const arrondirAuCentime = (valeur: number): number =>
	Math.round(valeur * 100) / 100

export const estEuro = (montant: Montant): montant is Montant<'€'> =>
	montant.unité === '€'
export const estEuroParTitreRestaurant = (
	montant: Montant
): montant is Montant<'€/titre-restaurant'> =>
	montant.unité === '€/titre-restaurant'
export const estEuroParMois = (
	montant: Montant
): montant is Montant<'€/mois'> => montant.unité === '€/mois'
export const estEuroParAn = (montant: Montant): montant is Montant<'€/an'> =>
	montant.unité === '€/an'
export const estEuroParJour = (
	montant: Montant
): montant is Montant<'€/jour'> => montant.unité === '€/jour'
export const estEuroParHeure = (
	montant: Montant
): montant is Montant<'€/heure'> => montant.unité === '€/heure'

export const montant = <U extends UnitéMonétaire>(
	valeur: number,
	unité: U
): Montant<U> =>
	makeMontant({
		valeur: arrondirAuCentime(valeur),
		unité,
	}) as Montant<U>

export const arrondirÀLEuro = <M extends Montant>(m: M): M =>
	montant(Math.round(m.valeur), m.unité) as M

export const fois = dual<
	<M extends Montant>(multiplicateur: number) => (a: M) => M,
	<M extends Montant>(a: M, multiplicateur: number) => M
>(
	2,
	<M extends Montant>(a: M, multiplicateur: number): M =>
		montant(a.valeur * multiplicateur, a.unité) as M
)

export const abattement = dual<
	<M extends Montant>(multiplicateur: number) => (a: M) => M,
	<M extends Montant>(a: M, multiplicateur: number) => M
>(
	2,
	<M extends Montant>(a: M, multiplicateur: number): M =>
		montant(a.valeur * (1 - multiplicateur), a.unité) as M
)

/**
 * Divise un montant par un nombre pour obtenir un nouveau montant de même unité.
 *
 * @param a - Le montant à diviser
 * @param diviseur - Le nombre par lequel diviser (ne peut pas être 0)
 * @returns Un nouveau montant de même unité que le montant initial, ou une erreur DivisionParZéro
 *
 * @example
 * const résultat = diviséPar(montant(100, '€'), 2) // Right(montant(50, '€'))
 */
export const diviséPar = dual<
	<M extends Montant>(
		diviseur: number
	) => (a: M) => Either.Either<M, DivisionParZéro>,
	<M extends Montant>(
		a: M,
		diviseur: number
	) => Either.Either<M, DivisionParZéro>
>(
	2,
	<M extends Montant>(
		a: M,
		diviseur: number
	): Either.Either<M, DivisionParZéro> => {
		if (diviseur === 0) {
			return Either.left(new DivisionParZéro())
		}

		return Either.right(montant(a.valeur / diviseur, a.unité) as M)
	}
)

export const estPositif = (montant: Montant): boolean => montant.valeur > 0
export const estNégatif = (montant: Montant): boolean => montant.valeur < 0
export const estZéro = (montant: Montant): boolean => montant.valeur === 0

export const montantToNumber = (montant: Montant): number => montant.valeur

export const montantToString = (
	montant: Montant,
	displayedUnit?: string
): string => {
	// eslint-disable-next-line no-irregular-whitespace
	return `${montant.valeur.toLocaleString('fr-FR')} ${
		displayedUnit ?? montant.unité
	}`
}

import { montant, Montant } from './Montant'
import { UnitéMonétairePonctuelle } from './Unites'

export type MontantPonctuel = Montant<UnitéMonétairePonctuelle>

export const euros = (valeur: number): Montant<'€'> => montant(valeur, '€')

export const eurosParTitreRestaurant = (
	valeur: number
): Montant<'€/titre-restaurant'> => montant(valeur, '€/titre-restaurant')

import { Either } from 'effect'
import { dual, pipe } from 'effect/Function'

import { DivisionParZéro, estZéro, montant, Montant } from './Montant'
import { pourcentage, Quantité } from './Quantite'
import { isUnitéMonétaireRécurrente, UnitéMonétaireRécurrente } from './Unites'

export type MontantRécurrent = Montant<UnitéMonétaireRécurrente>

export const isMontantRécurrent = (
	montant: Montant
): montant is MontantRécurrent => isUnitéMonétaireRécurrente(montant.unité)

export const toEurosParMois = (
	montantRécurrent: MontantRécurrent
): Montant<'€/mois'> => {
	let valeur = montantRécurrent.valeur
	switch (montantRécurrent.unité) {
		case '€/an':
			valeur = valeur / 12
			break
		case '€/jour':
			valeur = (valeur * 365) / 12
			break
		case '€/heure':
			valeur = (valeur * 24 * 365) / 12
			break
	}

	return montant(valeur, '€/mois')
}

export const toEurosParAn = (
	montantRécurrent: MontantRécurrent
): Montant<'€/an'> => {
	let valeur = montantRécurrent.valeur
	switch (montantRécurrent.unité) {
		case '€/mois':
			valeur = valeur * 12
			break
		case '€/jour':
			valeur = valeur * 365
			break
		case '€/heure':
			valeur = valeur * 24 * 365
			break
	}

	return montant(valeur, '€/an')
}

export const toEurosParJour = (
	montantRécurrent: MontantRécurrent
): Montant<'€/jour'> => {
	let valeur = montantRécurrent.valeur
	switch (montantRécurrent.unité) {
		case '€/an':
			valeur = valeur / 365
			break
		case '€/mois':
			valeur = (valeur * 12) / 365
			break
		case '€/heure':
			valeur = valeur * 24
			break
	}

	return montant(valeur, '€/jour')
}

export const toEurosParHeure = (
	montantRécurrent: MontantRécurrent
): Montant<'€/heure'> => {
	let valeur = montantRécurrent.valeur
	switch (montantRécurrent.unité) {
		case '€/an':
			valeur = valeur / (365 * 24)
			break
		case '€/mois':
			valeur = (valeur * 12) / (365 * 24)
			break
		case '€/jour':
			valeur = valeur / 24
			break
	}

	return montant(valeur, '€/heure')
}

export const eurosParMois = (valeur: number): Montant<'€/mois'> =>
	montant(valeur, '€/mois')

export const eurosParAn = (valeur: number): Montant<'€/an'> =>
	montant(valeur, '€/an')

export const eurosParJour = (valeur: number): Montant<'€/jour'> =>
	montant(valeur, '€/jour')

export const eurosParHeure = (valeur: number): Montant<'€/heure'> =>
	montant(valeur, '€/heure')

const convertitEn: {
	[U in UnitéMonétaireRécurrente]: (m: MontantRécurrent) => Montant<U>
} = {
	'€/mois': toEurosParMois,
	'€/an': toEurosParAn,
	'€/jour': toEurosParJour,
	'€/heure': toEurosParHeure,
}

const aligneLesValeurs = (
	montantA: MontantRécurrent,
	montantB: MontantRécurrent
): [valeurA: number, valeurB: number] => {
	if (montantA.unité !== montantB.unité) {
		const montantBAligné = convertitEn[montantA.unité](montantB)

		return [montantA.valeur, montantBAligné.valeur]
	}

	return [montantA.valeur, montantB.valeur]
}

export const plus = dual<
	(
		montantB: MontantRécurrent
	) => <A extends MontantRécurrent>(montantA: A) => A,
	<A extends MontantRécurrent>(montantA: A, montantB: MontantRécurrent) => A
>(
	2,
	<A extends MontantRécurrent>(montantA: A, montantB: MontantRécurrent): A => {
		const [valeurA, valeurB] = aligneLesValeurs(montantA, montantB)

		return montant(valeurA + valeurB, montantA.unité) as A
	}
)

export const moins = dual<
	(
		montantB: MontantRécurrent
	) => <A extends MontantRécurrent>(montantA: A) => A,
	<A extends MontantRécurrent>(montantA: A, montantB: MontantRécurrent) => A
>(
	2,
	<A extends MontantRécurrent>(montantA: A, montantB: MontantRécurrent): A => {
		const [valeurA, valeurB] = aligneLesValeurs(montantA, montantB)

		return montant(valeurA - valeurB, montantA.unité) as A
	}
)

export const sommeEnEurosParMois = (
	montants: ReadonlyArray<MontantRécurrent>
): Montant<'€/mois'> =>
	montants.map(toEurosParMois).reduce(plus, eurosParMois(0))

export const sommeEnEurosParAn = (
	montants: ReadonlyArray<MontantRécurrent>
): Montant<'€/an'> => montants.map(toEurosParAn).reduce(plus, eurosParAn(0))

/**
 * Calcule la proportion d'un montant par rapport à un autre.
 * Retourne un nombre représentant le ratio (sans unité).
 *
 * @param a - Le montant numérateur
 * @param diviseur - Le montant dénominateur (ne peut pas être zéro)
 * @returns Un nombre représentant le ratio a/diviseur, ou une erreur DivisionParZéro
 *
 * @example
 * // 25 €/mois par rapport à 100 €/mois donne 0.25 (soit 25%)
 * const résultat = parRapportÀ(eurosParMois(25), eurosParMois(100)) // Right(0.25)
 */
export const parRapportÀ = dual<
	(
		diviseur: MontantRécurrent
	) => (montantA: MontantRécurrent) => Either.Either<number, DivisionParZéro>,
	(
		montantA: MontantRécurrent,
		diviseur: MontantRécurrent
	) => Either.Either<number, DivisionParZéro>
>(
	2,
	(
		montantA: MontantRécurrent,
		diviseur: MontantRécurrent
	): Either.Either<number, DivisionParZéro> => {
		if (estZéro(diviseur)) {
			return Either.left(new DivisionParZéro())
		}

		const [numérateur, dénominateur] = aligneLesValeurs(montantA, diviseur)

		return Either.right(numérateur / dénominateur)
	}
)

export const pourcentageParRapportÀ = dual<
	(
		diviseur: MontantRécurrent
	) => (
		montantA: MontantRécurrent
	) => Either.Either<Quantité<'%'>, DivisionParZéro>,
	(
		montantA: MontantRécurrent,
		diviseur: MontantRécurrent
	) => Either.Either<Quantité<'%'>, DivisionParZéro>
>(
	2,
	(
		montantA: MontantRécurrent,
		diviseur: MontantRécurrent
	): Either.Either<Quantité<'%'>, DivisionParZéro> =>
		pipe(
			montantA,
			parRapportÀ(diviseur),
			Either.map((rapport) => pourcentage(100 * rapport))
		)
)

export const estPlusGrandQue = dual<
	(montantB: MontantRécurrent) => (montantA: MontantRécurrent) => boolean,
	(montantA: MontantRécurrent, montantB: MontantRécurrent) => boolean
>(2, (montantA: MontantRécurrent, montantB: MontantRécurrent): boolean => {
	const [valeurA, valeurB] = aligneLesValeurs(montantA, montantB)

	return valeurA > valeurB
})

export const estPlusPetitQue = dual<
	(montantB: MontantRécurrent) => (montantA: MontantRécurrent) => boolean,
	(montantA: MontantRécurrent, montantB: MontantRécurrent) => boolean
>(2, (montantA: MontantRécurrent, montantB: MontantRécurrent): boolean => {
	const [valeurA, valeurB] = aligneLesValeurs(montantA, montantB)

	return valeurA < valeurB
})

export const estPlusGrandOuÉgalÀ = dual<
	(montantB: MontantRécurrent) => (montantA: MontantRécurrent) => boolean,
	(montantA: MontantRécurrent, montantB: MontantRécurrent) => boolean
>(2, (montantA: MontantRécurrent, montantB: MontantRécurrent): boolean => {
	const [valeurA, valeurB] = aligneLesValeurs(montantA, montantB)

	return valeurA >= valeurB
})

export const estPlusPetitOuÉgalÀ = dual<
	(montantB: MontantRécurrent) => (montantA: MontantRécurrent) => boolean,
	(montantA: MontantRécurrent, montantB: MontantRécurrent) => boolean
>(2, (montantA: MontantRécurrent, montantB: MontantRécurrent): boolean => {
	const [valeurA, valeurB] = aligneLesValeurs(montantA, montantB)

	return valeurA <= valeurB
})

export type OuiNon = 'oui' | 'non'

export const isOuiNon = (value: unknown): value is OuiNon =>
	typeof value === 'string' && (value === 'oui' || value === 'non')

export const toOuiNon = (value: boolean): OuiNon => (value ? 'oui' : 'non')

export const fromOuiNon = (value: OuiNon | undefined): boolean =>
	value === 'oui'

import { TFunction } from 'i18next'
import Engine from 'publicodes'

import { DottedName } from './publicodes/DottedName'
import { RaccourciPublicodes } from './RaccourciPublicodes'
import { SituationPublicodes } from './SituationPublicodes'

export type PublicodesSimulationConfig = Partial<{
	nomModèle: NomModèle

	/**
	 * Objectifs exclusifs de la simulation : si une règle change dans la situation
	 * et qu'elle est dans `objectifs exclusifs`, alors toute les autres règles
	 * dans `objectifs exclusifs` seront supprimées de la situation
	 */
	'objectifs exclusifs': DottedName[]

	/**
	 * Objectifs de la simulation
	 */
	objectifs?: DottedName[]

	/**
	 * La situation de base du simulateur
	 */
	situation: SituationPublicodes

	questions: QuestionsAutoGénérées | QuestionsÉditorialisées

	'unité par défaut'?: string

	'règles à ignorer pour déclencher les questions'?: DottedName[]

	'notifications à ignorer'?: DottedName[]

	autoloadLastSimulation: boolean
}>

export type NomModèle = 'modele-social' | 'modele-as' | 'modele-ti'

export type QuestionsAutoGénérées = {
	// Questions non prioritaires, elles aparaîtront en fin de simulation
	'non prioritaires'?: DottedName[]
	/**
	 * Liste blanche des questions qui sont affichées à l'utilisateurice.
	 * Cela peut également servir pour prioriser des questions
	 * en mettant une string vide comme dernier élément.
	 */
	liste?: (DottedName | '')[]
	// Questions qui ne sont pas affichées à l'utilisateurice
	'liste noire'?: DottedName[]
	// Questions "raccourcis" sélectionnables en bas du simulateur
	raccourcis?: RaccourciPublicodes[]
}

export type Question = {
	libellé: (t: TFunction) => string
	dottedName: DottedName
}

// TODO: quand QuestionsAutoGénérées ne sera plus utilisé,
// supprimer l'export de QuestionsÉditorialisées et le
// remplacer ailleurs par le type de PublicodesSimulationConfig['questions']
export type QuestionsÉditorialisées = {
	'questions principales': Question[]
	'groupes de questions': Record<
		string,
		{
			titre: (t: TFunction) => string
			réponse?: (engine: Engine, t: TFunction) => string
			liste: Question[]
		}
	>
}

import { Data } from 'effect'
import { isObject } from 'effect/Predicate'

import { UnitéQuantité } from './Unites'

export interface Quantité<T extends UnitéQuantité = UnitéQuantité> {
	readonly _tag: 'Quantité'
	readonly valeur: number
	readonly unité: T
}

export const isQuantité = (something: unknown): something is Quantité =>
	isObject(something) && '_tag' in something && something._tag === 'Quantité'

const makeQuantité = Data.tagged<Quantité>('Quantité')

export const pourcentage = (valeur: number): Quantité<'%'> =>
	quantité(valeur, '%')

export const heuresParMois = (valeur: number): Quantité<'heures/mois'> =>
	quantité(valeur, 'heures/mois')

export const heuresParSemaine = (valeur: number): Quantité<'heures/semaine'> =>
	quantité(valeur, 'heures/semaine')

export const jours = (valeur: number): Quantité<'jours'> =>
	quantité(valeur, 'jours')

export const joursOuvrés = (valeur: number): Quantité<'jours ouvrés'> =>
	quantité(valeur, 'jours ouvrés')

export const mois = (valeur: number): Quantité<'mois'> =>
	quantité(valeur, 'mois')

export const trimestreCivil = (valeur: number): Quantité<'trimestre civil'> =>
	quantité(valeur, 'trimestre civil')

export const annéeCivile = (valeur: number): Quantité<'année civile'> =>
	quantité(valeur, 'année civile')

export const employés = (valeur: number): Quantité<'employés'> =>
	quantité(valeur, 'employés')

export const titresRestaurantParMois = (
	valeur: number
): Quantité<'titre-restaurant/mois'> =>
	quantité(valeur, 'titre-restaurant/mois')

export const trimestresValidésParAn = (
	valeur: number
): Quantité<'trimestre validé/an'> => quantité(valeur, 'trimestre validé/an')

export const pointsParAn = (valeur: number): Quantité<'point/an'> =>
	quantité(valeur, 'point/an')

export const quantité = <U extends UnitéQuantité>(
	valeur: number,
	unité: U
): Quantité<U> =>
	makeQuantité({
		valeur,
		unité,
	}) as Quantité<U>

export const quantitéToString = (
	quantité: Quantité,
	displayedUnit?: string
): string => {
	// eslint-disable-next-line no-irregular-whitespace
	return `${quantité.valeur} ${displayedUnit ?? quantité.unité}`
}

export const arrondirÀLUnité = <Q extends Quantité>(q: Q): Q =>
	quantité(Math.round(q.valeur), q.unité) as Q

import { DottedName } from './publicodes/DottedName'

export type RaccourciPublicodes = {
	label: string
	dottedName: DottedName
}

import { Brand } from '@/domaine/Brand'

export type Siren = Brand<string, 'Siren'>
export const siren = (value: string): Siren => value as Siren

export type Siret = Brand<string, 'Siret'>
export const siret = (value: string): Siret => value as Siret

import { AnyAction } from 'redux'

export interface Situation {
	_tag: 'Situation'
	_type?: string
}

export type SituationAction = AnyAction & {
	_situationType: string
}

import { ASTNode, PublicodesExpression } from 'publicodes'

import { DottedName } from '@/domaine/publicodes/DottedName'

export type SituationPublicodes = Partial<
	Record<DottedName, PublicodesExpression | ASTNode>
>

export type UnitéMonétairePonctuelle = '€' | '€/titre-restaurant'
export type UnitéMonétaireRécurrente = '€/mois' | '€/an' | '€/jour' | '€/heure'
export type UnitéMonétaire = UnitéMonétairePonctuelle | UnitéMonétaireRécurrente

const UNITÉS_MONÉTAIRES = [
	'€',
	'€/titre-restaurant',
	'€/an',
	'€/mois',
	'€/jour',
	'€/heure',
]

export const isUnitéMonétaire = (unité?: string): unité is UnitéMonétaire =>
	UNITÉS_MONÉTAIRES.includes(unité as UnitéMonétaire)

export const isUnitéMonétaireRécurrente = (
	unité?: string
): unité is UnitéMonétaireRécurrente =>
	isUnitéMonétaire(unité as UnitéMonétaire) &&
	unité !== '€' &&
	unité !== '€/titre-restaurant'

const UNITÉS_QUANTITÉS = [
	'%',
	'heures/mois',
	'heures/semaine',
	'jours',
	'jours ouvrés',
	'mois',
	'trimestre civil',
	'année civile',
	'employés',
	'titre-restaurant/mois',
	'trimestre validé/an',
	'point/an',
]

export type UnitéQuantité = (typeof UNITÉS_QUANTITÉS)[number]

export const isUnitéQuantité = (unité?: string): unité is UnitéQuantité =>
	UNITÉS_QUANTITÉS.includes(unité as UnitéQuantité)

/**
 * Représente une valeur qui change chaque année (seuils, plafonds, taux...)
 */
export type ValeurAnnuelle<T> = Readonly<Record<number, T>>

/**
 * Retourne la valeur en vigueur pour l'année demandée : celle de l'année la plus
 * récente qui lui est antérieure ou égale, ou la plus ancienne connue si l'année
 * précède la table.
 */
export const valeurPourAnnée = <T>(
	valeurs: ValeurAnnuelle<T>,
	année: number
): T => {
	const annéesConnues = Object.keys(valeurs).map(Number)
	const annéesEnVigueur = annéesConnues.filter((connue) => connue <= année)

	const annéeApplicable =
		annéesEnVigueur.length > 0
			? Math.max(...annéesEnVigueur)
			: Math.min(...annéesConnues)

	return valeurs[annéeApplicable]
}

/**
 * Retourne la valeur pour l'année courante, ou la dernière valeur disponible
 * si l'année courante n'est pas encore renseignée.
 */
export const valeurCourante = <T>(valeurs: ValeurAnnuelle<T>): T =>
	valeurPourAnnée(valeurs, new Date().getFullYear())

import { pipe } from 'effect'
import * as O from 'effect/Option'
import { EvaluatedNode, PublicodesExpression, serializeUnit } from 'publicodes'

import { Montant } from '@/domaine/Montant'
import { euros, eurosParTitreRestaurant } from '@/domaine/MontantPonctuel'
import {
	eurosParAn,
	eurosParHeure,
	eurosParJour,
	eurosParMois,
} from '@/domaine/MontantRecurrent'

export const MontantAdapter = {
	decode: (node: EvaluatedNode): O.Option<Montant> => {
		if (
			node.nodeValue === null ||
			node.nodeValue === undefined ||
			typeof node.nodeValue === 'boolean'
		) {
			return O.none()
		}

		const numberValue =
			typeof node.nodeValue === 'string'
				? parseFloat(node.nodeValue)
				: node.nodeValue

		if (isNaN(numberValue)) return O.none()

		if (!node.unit) return O.some(euros(numberValue))

		const formattedUnit = serializeUnit(node.unit)

		switch (formattedUnit) {
			case '€':
				return O.some(euros(numberValue))
			case '€/an':
				return O.some(eurosParAn(numberValue))
			case '€/mois':
				return O.some(eurosParMois(numberValue))
			case '€/jour':
				return O.some(eurosParJour(numberValue))
			case '€/heure':
				return O.some(eurosParHeure(numberValue))
			case '€/titre-restaurant':
				return O.some(eurosParTitreRestaurant(numberValue))
			default:
				console.warn(
					`Le montant ${numberValue} est en ${formattedUnit}, ce n’est pas pris en charge.`
				)

				return O.none()
		}
	},
	encode: (valeur: O.Option<Montant>) =>
		pipe(
			valeur,
			O.map((m) => `${m.valeur} ${m.unité}`),
			O.getOrUndefined
		) satisfies PublicodesExpression | undefined,
}

import { pipe } from 'effect'
import * as O from 'effect/Option'
import { Evaluation, PublicodesExpression } from 'publicodes'

import { OuiNon, toOuiNon } from '@/domaine/OuiNon'

export const OuiNonAdapter = {
	decode: (valeur: Evaluation<boolean>): O.Option<OuiNon> =>
		pipe(
			valeur,
			O.fromNullable,
			O.map((brute) => toOuiNon(brute))
		),
	encode: (valeur: O.Option<OuiNon>) =>
		O.getOrUndefined(valeur) satisfies PublicodesExpression | undefined,
}

import { pipe } from 'effect'
import { isNumber } from 'effect/Number'
import * as O from 'effect/Option'
import { isBoolean } from 'effect/Predicate'
import * as R from 'effect/Record'
import Engine, {
	ASTNode,
	EvaluatedNode,
	PublicodesExpression,
} from 'publicodes'

import {
	isIsoDate,
	isoDateToPublicodesDate,
	isPublicodesStandardDate,
	publicodesDateToIsoDate,
} from '@/domaine/Date'
import { MontantAdapter } from '@/domaine/engine/MontantAdapter'
import { OuiNonAdapter } from '@/domaine/engine/OuiNonAdapter'
import { isMontant, Montant } from '@/domaine/Montant'
import { isOuiNon } from '@/domaine/OuiNon'
import { isQuantité, Quantité } from '@/domaine/Quantite'

import { QuantitéAdapter } from './QuantitéAdapter'

export type ValeurPublicodes = string | Montant | Quantité | number

const decode = (node: EvaluatedNode): O.Option<ValeurPublicodes> => {
	if (node.nodeValue === null || node.nodeValue === undefined) {
		return O.none()
	}

	if (isBoolean(node.nodeValue)) {
		return OuiNonAdapter.decode(node.nodeValue)
	}

	if (typeof node.nodeValue === 'string') {
		if (isPublicodesStandardDate(node.nodeValue)) {
			const date = publicodesDateToIsoDate(node.nodeValue)

			return O.some(date)
		}

		const match = node.nodeValue.match(/'(.*)'/)
		if (match?.length) {
			return O.some(match[1])
		}

		return O.some(node.nodeValue)
	}

	if (typeof node.nodeValue === 'number') {
		if (node.unit?.numerators.includes('€')) {
			return MontantAdapter.decode(node)
		}

		if (node.unit?.denominators.length || node.unit?.numerators.length) {
			return QuantitéAdapter.decode(node)
		} else {
			return O.some(node.nodeValue)
		}
	}

	// eslint-disable-next-line no-console
	console.warn('Incapable de décoder', node.nodeValue)

	return O.none()
}

const encode = (
	optionalValeur: O.Option<ValeurPublicodes>
): PublicodesExpression | undefined => {
	if (O.isNone(optionalValeur)) {
		return undefined
	}

	const valeur = O.getOrUndefined(optionalValeur) as ValeurPublicodes

	if (isOuiNon(valeur)) {
		return valeur
	}

	if (isMontant(valeur)) {
		return MontantAdapter.encode(optionalValeur as O.Some<Montant>)
	}

	if (isQuantité(valeur)) {
		return QuantitéAdapter.encode(optionalValeur as O.Some<Quantité>)
	}

	if (isNumber(valeur)) return valeur

	if (isIsoDate(valeur)) {
		return isoDateToPublicodesDate(valeur)
	}

	return `'${valeur}'`
}

export const PublicodesAdapter = { decode, encode }

export const decodeSuggestions = <T extends ValeurPublicodes>(
	suggestions: Record<string, ASTNode>,
	engine: Engine
): Record<string, T> =>
	pipe(
		suggestions,
		R.map((node) => pipe(engine.evaluate(node), PublicodesAdapter.decode)),
		R.filter(O.isSome),
		R.map(O.getOrThrow)
	) as Record<string, T>

/**
 * Décode l'attribut Publicodes "arrondi" qui peut :
 * - être absent
 * - valoir "oui"
 * - valoir "1 décimale"
 * - valoir "X décimales" avec X un nombre > 1
 */
export const decodeArrondi = (
	arrondiPublicodes?: string
): number | undefined => {
	if (arrondiPublicodes === 'oui') {
		return 0
	}

	const regExpMatch = arrondiPublicodes?.match(/^(\d+) décimales?$/)
	if (regExpMatch) {
		return +regExpMatch[1]
	}
}

import { pipe } from 'effect'
import { join, map } from 'effect/Array'
import * as O from 'effect/Option'
import { split } from 'effect/String'
import { EvaluatedNode, PublicodesExpression, serializeUnit } from 'publicodes'

import { quantité, Quantité } from '@/domaine/Quantite'

export const QuantitéAdapter = {
	decode: (node: EvaluatedNode): O.Option<Quantité> => {
		if (
			node.nodeValue === null ||
			node.nodeValue === undefined ||
			typeof node.nodeValue === 'boolean'
		) {
			return O.none()
		}

		const numberValue =
			typeof node.nodeValue === 'string'
				? parseFloat(node.nodeValue)
				: node.nodeValue

		if (isNaN(numberValue)) return O.none()

		const formattedUnit =
			node.unit && serializeUnit(node.unit, 2, unitFormatter)

		if (!formattedUnit) {
			return O.none()
		}

		return O.some(quantité(numberValue, formattedUnit))
	},
	encode: (valeur: O.Option<Quantité>) =>
		pipe(
			valeur,
			O.map((q) =>
				q.unité === '%' ? `${q.valeur}${q.unité}` : `${q.valeur} ${q.unité}`
			),
			O.getOrUndefined
		) satisfies PublicodesExpression | undefined,
}

const unitFormatter = (unit: string, count: number): string => {
	const unitToPluralize = [
		'heure',
		'jour',
		'jour ouvré',
		'trimestre civil',
		'année civile',
		'employé',
	]
	if (unitToPluralize.includes(unit) && count > 1) {
		return pipe(
			unit,
			split(' '),
			map((word) => `${word}s`),
			join(' ')
		)
	}

	return unit
}

import { Order, pipe } from 'effect'
import { filter, map, NonEmptyArray, sort } from 'effect/Array'
import Engine from 'publicodes'

import { ComparateurConfig } from '@/domaine/ComparateurConfig'
import { listeLesVariablesManquantes } from '@/domaine/engine/listeLesVariablesManquantes'
import { DottedName } from '@/domaine/publicodes/DottedName'
import {
	PublicodesSimulationConfig,
	QuestionsAutoGénérées,
} from '@/domaine/PublicodesSimulationConfig'
import { QuestionRépondue } from '@/store/reducers/simulation.reducer'

export const détermineLesProchainesQuestions = (
	engines: NonEmptyArray<Engine>,
	config: PublicodesSimulationConfig | ComparateurConfig,
	answeredQuestions: Array<QuestionRépondue> = []
): Array<DottedName> => {
	const {
		liste = [],
		'liste noire': listeNoire = [],
		'non prioritaires': nonPrioritaires = [],
	} = (config.questions as QuestionsAutoGénérées) || {}

	const score = (question: DottedName) => {
		const indexList = liste.indexOf(question)
		const scoreDeListe =
			(indexList > -1
				? indexList
				: liste.findIndex((name) => question.startsWith(name))) + 1
		const indexNonPrioritaire =
			nonPrioritaires.findIndex((name) => question.startsWith(name)) + 1
		const différenceCoeff = questionDifference(
			question,
			answeredQuestions.slice(-1)[0]?.règle
		)

		return scoreDeListe + indexNonPrioritaire + différenceCoeff
	}

	return pipe(
		listeLesVariablesManquantes(engines, [
			...(config['objectifs exclusifs'] ?? []),
			...(config.objectifs ?? []),
		]),
		Object.entries,
		sort(([, a], [, b]) => Order.number(b, a)),
		map(([règle]) => règle as DottedName),
		filter(
			(règle: DottedName) =>
				!answeredQuestions.some((question) => question.règle === règle)
		),
		filter(
			(règle: DottedName) =>
				(!liste.length ||
					liste.some((question) => règle.startsWith(question))) &&
				(!listeNoire.length ||
					!listeNoire.some((question) => règle === question)) &&
				(!config['objectifs exclusifs']?.length ||
					!config['objectifs exclusifs'].includes(règle))
		),
		sort((règleA: DottedName, règleB: DottedName) =>
			Order.number(score(règleA), score(règleB))
		),
		filter(
			(règle: DottedName) =>
				engines[0].getRule(règle).rawNode.question !== undefined
		)
	)
}

// Max : 1
// Min -> 0
const questionDifference = (ruleA = '', ruleB = '') => {
	if (ruleA === ruleB) {
		return 0
	}
	const partsA = ruleA.split(' . ')
	const partsB = ruleB.split(' . ')

	return 1 / (1 + partsA.findIndex((val, i) => partsB?.[i] !== val))
}

import Engine, { Situation } from 'publicodes'

import { chargeModèle } from '@/utils/chargeModele'
import { engineFactory } from '@/utils/publicodes/engineFactory'

import { DottedName } from '../publicodes/DottedName'
import { NomModèle } from '../PublicodesSimulationConfig'

type EngineCacheEntry = {
	engine?: Engine<DottedName>
	promise?: Promise<Engine<DottedName>>
}

const cache = new Map<NomModèle, EngineCacheEntry>()

export const getCachedEngine = (
	nomModèle: NomModèle
): Engine<DottedName> | undefined => cache.get(nomModèle)?.engine

export const setEngineSituation = (
	nomModèle: NomModèle,
	situation: Situation<DottedName>
): void => {
	const engine = getCachedEngine(nomModèle)
	engine?.setSituation(situation)
}

export const getOrCreateEnginePromise = (
	nomModèle: NomModèle
): Promise<Engine<DottedName>> => {
	const existing = cache.get(nomModèle)

	if (existing?.engine) {
		return Promise.resolve(existing.engine)
	}

	if (existing?.promise) {
		return existing.promise
	}

	const promise = chargeModèle(nomModèle).then((modèle) => {
		const engine = engineFactory(modèle.default, nomModèle)
		cache.set(nomModèle, {
			engine,
		})

		return engine
	})

	cache.set(nomModèle, {
		promise,
	})

	return promise
}

export const loadEngine = (nomModèle: NomModèle) => {
	let status: 'pending' | 'success' | 'error' = 'pending'
	let result: Engine<DottedName>
	let errorMessage: string | undefined

	const promise = getOrCreateEnginePromise(nomModèle)
		.then((engine: Engine<DottedName>) => {
			status = 'success'
			result = engine

			return engine
		})
		.catch((error: Error) => {
			status = 'error'
			errorMessage =
				(error instanceof Error ? error.message : String(error)) ??
				'Erreur inconnue'

			throw error
		})

	return {
		read() {
			if (status === 'error') {
				throw new Error(errorMessage)
			}

			if (status === 'success') {
				return result
			}

			throw promise
		},
	}
}

import rules, { RègleModèleSocial } from 'modele-social'
import Engine, { PublicodesExpression, Unit } from 'publicodes'

import { SituationPublicodes } from '@/domaine/SituationPublicodes'
import { engineFactory } from '@/utils/publicodes/engineFactory'

let publicodesEngine: Engine | null = null

function getPublicodesEngine(): Engine<RègleModèleSocial> {
	if (!publicodesEngine) {
		resetPublicodesEngine()
	}

	return publicodesEngine as Engine<RègleModèleSocial>
}

function resetPublicodesEngine(): void {
	publicodesEngine = engineFactory(rules)
}

export const evalueAvecPublicodes = <TypeRetour>(
	situation: SituationPublicodes,
	règle: PublicodesExpression,
	unité?: Unit
) =>
	getPublicodesEngine()
		.setSituation(situation)
		.evaluate(unité ? { valeur: règle, unité } : règle).nodeValue as TypeRetour

import { pipe } from 'effect'
import { flatMap, NonEmptyArray, reduce } from 'effect/Array'
import Engine, { utils } from 'publicodes'

import { DottedName } from '@/domaine/publicodes/DottedName'

type MissingVariables = Partial<Record<DottedName, number>>

export const listeLesVariablesManquantes = (
	engines: NonEmptyArray<Engine>,
	objectifs: ReadonlyArray<DottedName>
): MissingVariables => {
	return pipe(
		engines,
		flatMap((engine) =>
			objectifs.map(
				(objectif) => engine.evaluate(objectif).missingVariables ?? {}
			)
		),
		reduce({}, mergeMissing),
		treatAPIMissingVariables(engines)
	)
}

const mergeMissing = (
	left: Record<string, number> | undefined = {},
	right: Record<string, number> | undefined = {}
): Record<string, number> =>
	Object.fromEntries(
		[...Object.keys(left), ...Object.keys(right)].map((key) => [
			key,
			(left[key] ?? 0) + (right[key] ?? 0),
		])
	)

/**
 * Merge objectifs missings that depends on the same input field.
 *
 * For instance, the commune field (API) will fill `commune . nom` `commune . taux versement transport`, `commune . département`, etc.
 */
const treatAPIMissingVariables =
	<Name extends string>(engines: Array<Engine<Name>>) =>
	(
		missingVariables: Partial<Record<Name, number>>
	): Partial<Record<Name, number>> =>
		(Object.entries(missingVariables) as Array<[Name, number]>).reduce(
			(missings, [name, value]: [Name, number]) => {
				const parentName = utils.ruleParent(name) as Name
				if (parentName && engines.some(engineHasRule(parentName))) {
					missings[parentName] = (missings[parentName] ?? 0) + value

					return missings
				}
				missings[name] = value

				return missings
			},
			{} as Partial<Record<Name, number>>
		)

const engineHasRule =
	<Name extends string>(rule: Name) =>
	(engine: Engine<Name>) =>
		engine.getRule(rule).rawNode.API

import { DottedName } from './publicodes/DottedName'

export const estPasQuestionEnListeNoire =
	(listeNoire: DottedName[]) =>
	(question: DottedName): boolean =>
		!listeNoire.some((préfixe) => question.startsWith(préfixe))

export const PARAMÈTRE_SITUATION = 'situation'

import { Contexte } from '@/domaine/Contexte'
import { Montant, montantToNumber } from '@/domaine/Montant'

export const AutoEntrepreneurContexteDansPublicodes: Contexte = {
	'entreprise . catégorie juridique': "'EI'",
	'entreprise . catégorie juridique . EI . auto-entrepreneur': 'oui',
	'dirigeant . auto-entrepreneur': 'oui',
}

export const AutoEntrepreneurCotisationsEtContributionsDansPublicodes = {
	enEurosParAn: {
		valeur: 'dirigeant . auto-entrepreneur . cotisations et contributions',
		unité: '€/an',
	},
	enEurosParMois: {
		valeur: 'dirigeant . auto-entrepreneur . cotisations et contributions',
		unité: '€/mois',
	},
}

export const AutoEntrepreneurChiffreAffaireDansPublicodes = {
	fromMontant: (montant: Montant<'€/an'>) => ({
		"dirigeant . auto-entrepreneur . chiffre d'affaires": `${montantToNumber(
			montant
		)} €/an`,
	}),
}

import { RègleModèleAssimiléSalarié } from 'modele-as'
import { RègleModèleSocial } from 'modele-social'
import { RègleModèleTravailleurIndépendant } from 'modele-ti'

export type DottedName =
	| RègleModèleSocial
	| RègleModèleAssimiléSalarié
	| RègleModèleTravailleurIndépendant

import { EvaluatedNode, RuleNode } from 'publicodes'

import { DottedName } from './DottedName'

export type EvaluatedRule = EvaluatedNode &
	RuleNode & { dottedName: DottedName }

// To add a new notification to a simulator, you should create a publicodes rule
// with the "type: notification" attribute. The display can be customized with
// the "sévérité" attribute. The notification will only be displayed if the

import { Option } from 'effect'
import Engine, { RuleNode } from 'publicodes'

import { PublicodesAdapter } from '../engine/PublicodesAdapter'
import { DottedName } from './DottedName'

// publicodes rule is applicable.
export type Notification = {
	dottedName: DottedName | 'inversion fail'
	sévérité: 'avertissement' | 'information'
	description: RuleNode['rawNode']['description']
	résumé?: RuleNode['rawNode']['description']
}

export const getNotification = (engine: Engine, dottedName: DottedName) => {
	const rules = engine.getParsedRules()
	if (!(dottedName in rules)) {
		return null
	}

	const rule = rules[dottedName]

	if (rule.rawNode.type !== 'notification') {
		return null
	}

	const estNoficationActive = PublicodesAdapter.decode(
		engine.evaluate(dottedName)
	)

	if (
		Option.isNone(estNoficationActive) ||
		estNoficationActive.value !== 'oui'
	) {
		return null
	}

	return getNotificationFromRawNode(rule)
}

export const getNotifications = (engine: Engine) =>
	Object.values(engine.getParsedRules())
		.filter(
			(rule) =>
				rule.rawNode.type === 'notification' &&
				!!engine.evaluate(rule.dottedName).nodeValue
		)
		.map(getNotificationFromRawNode)

const getNotificationFromRawNode = ({
	dottedName,
	rawNode: { sévérité, résumé, description },
}: RuleNode) =>
	({
		dottedName,
		sévérité,
		résumé,
		description,
	}) as Notification

import { Rule } from 'publicodes'

export type Rules = Record<string, Rule>

import { Montant, montantToNumber } from '@/domaine/Montant'

export const TravailleurIndependantContexteDansPublicodes = {
	'dirigeant . régime social': "'indépendant'",
	'entreprise . imposition': "'IR'",
	'entreprise . catégorie juridique': "''",
	salarié: 'non',
}

export const TravailleurIndependantChiffreAffaireDansPublicodes = {
	fromMontant: (montant: Montant<'€/an'>) => ({
		"entreprise . chiffre d'affaires": `${montantToNumber(montant)} €/an`,
	}),
}

export const TravailleurIndependantCotisationsEtContributionsDansPublicodes = {
	enEurosParAn: 'dirigeant . indépendant . cotisations et contributions',
}

import { TFunction } from 'i18next'
import Engine from 'publicodes'

import { QuestionPublicodes } from './QuestionPublicodes'

export type GroupeDeQuestionsPublicodes = {
	titre: (t: TFunction) => string
	réponse?: (engine: Engine, t: TFunction) => string
	liste: QuestionPublicodes[]
}

import { TFunction } from 'i18next'

import { DottedName } from '../publicodes/DottedName'

export interface QuestionPublicodes {
	_tag: 'QuestionPublicodes'
	id: DottedName
	libellé: (t: TFunction) => string
	applicable: () => boolean
	Valeur: React.FunctionComponent
}

export { type QuestionPublicodes } from './QuestionPublicodes'
export { type GroupeDeQuestionsPublicodes } from './GroupeDeQuestionsPublicodes'

export const relativeDottedName = (
	rootDottedName: string,
	childDottedName: string
) => childDottedName.replace(rootDottedName + ' . ', '')

import * as R from 'effect/Record'

import { ValeurPublicodes } from '@/domaine/engine/PublicodesAdapter'
import { isExpressionAvecUnité } from '@/domaine/ExpressionPublicodes'
import { isMontant } from '@/domaine/Montant'
import { DottedName } from '@/domaine/publicodes/DottedName'
import { isQuantité } from '@/domaine/Quantite'
import { SituationPublicodes } from '@/domaine/SituationPublicodes'
import { SearchParamsAdapter, ValeurDomaine } from '@/SearchParamsAdapter'

export const TARGET_UNIT_PARAM = 'unité'

const isEncodable = (value: unknown): value is ValeurDomaine =>
	typeof value === 'string' ||
	typeof value === 'number' ||
	isMontant(value) ||
	isQuantité(value)

export const getSearchParamsFromSituation = (
	situation: SituationPublicodes,
	targetUnit: string
) => {
	const searchParams = new URLSearchParams()
	searchParams.set(TARGET_UNIT_PARAM, targetUnit)

	R.map(situation as Record<DottedName, unknown>, (value, dottedName) => {
		if (isEncodable(value)) {
			searchParams.set(dottedName as string, SearchParamsAdapter.encode(value))

			return
		}
		if (isExpressionAvecUnité(value)) {
			searchParams.set(
				dottedName as string,
				SearchParamsAdapter.encode(`${value.valeur} ${value.unité}`)
			)
		}
	})

	searchParams.sort()

	return searchParams
}

export const getSituationFromSearchParams = (
	searchParams: URLSearchParams,
	rules: DottedName[]
): Record<DottedName, ValeurPublicodes> => {
	const situation = {} as Record<DottedName, ValeurPublicodes>

	searchParams.forEach((value, paramName) => {
		const dottedName = paramName as DottedName
		if (rules.includes(dottedName)) {
			situation[dottedName] = SearchParamsAdapter.decode(value)
		}
	})

	return situation
}

const PARAMS_RÉSERVÉS = new Set([
	TARGET_UNIT_PARAM,
	'integratorUrl',
	'lang',
	'couleur',
])

export const getRèglesIgnoréesFromSearchParams = (
	searchParams: URLSearchParams,
	rules: DottedName[]
): DottedName[] =>
	[...searchParams.keys()]
		.filter(
			(key) => !PARAMS_RÉSERVÉS.has(key) && !rules.includes(key as DottedName)
		)
		.map((key) => key as DottedName)

export const getTargetUnitFromSearchParams = (
	searchParams: URLSearchParams
): string | null =>
	searchParams.has(TARGET_UNIT_PARAM)
		? searchParams.get(TARGET_UNIT_PARAM)
		: null

import * as O from 'effect/Option'

import {
	PublicodesAdapter,
	ValeurPublicodes,
} from '@/domaine/engine/PublicodesAdapter'
import { DottedName } from '@/domaine/publicodes/DottedName'
import { ImmutableType } from '@/types/utils'
import { objectTransform } from '@/utils'

import { PublicodesSimulationConfig } from './PublicodesSimulationConfig'
import { SituationPublicodes } from './SituationPublicodes'

export function updateSituation(
	config: ImmutableType<PublicodesSimulationConfig>,
	currentSituation: SituationPublicodes,
	dottedName: DottedName,
	value: ValeurPublicodes
): SituationPublicodes {
	const objectifsExclusifs = config['objectifs exclusifs'] ?? []

	const encoded = PublicodesAdapter.encode(O.some(value))

	if (!objectifsExclusifs.includes(dottedName)) {
		return {
			...currentSituation,
			[dottedName]: encoded,
		}
	}

	const objectifsToReset = objectifsExclusifs.filter(
		(name) => name !== dottedName
	)

	const clearedSituation = objectTransform(currentSituation, (entries) =>
		entries.filter(
			([dottedName]) => !objectifsToReset.includes(dottedName as DottedName)
		)
	)

	return {
		...clearedSituation,
		[dottedName]: encoded,
	}
}

import { pipe } from 'effect'
import * as O from 'effect/Option'
import * as R from 'effect/Record'

import {
	PublicodesAdapter,
	ValeurPublicodes,
} from '@/domaine/engine/PublicodesAdapter'
import { DottedName } from '@/domaine/publicodes/DottedName'
import { SituationPublicodes } from '@/domaine/SituationPublicodes'

/**
 * Enregistre une question à choix multiple
 * i.e. met à jour une liste de sous-règles
 * NB: ne gère pas le cas où la règle parente est un objectif exclusif
 * (réinitilisation des autres objectifs exclusifs nécessaire)
 */
export function updateSituationMultiple(
	currentSituation: SituationPublicodes,
	préfixe: DottedName,
	valeurs: Record<string, ValeurPublicodes>
): SituationPublicodes {
	const nouvellesValeurs = pipe(
		valeurs,
		R.mapKeys((suffixe) => `${préfixe} . ${suffixe}`),
		R.map((valeur) => PublicodesAdapter.encode(O.some(valeur)))
	)

	return { ...currentSituation, ...nouvellesValeurs }
}

import Engine from 'publicodes'

import { DottedName } from '@/domaine/publicodes/DottedName'
import { QuestionRépondue } from '@/store/reducers/simulation.reducer'

export const estCeQueLaQuestionPublicodesEstRépondue =
	(engine: Engine<DottedName>, questionsRépondues: QuestionRépondue[]) =>
	(dottedName: DottedName): boolean => {
		const estDirectementRépondue = questionsRépondues.some(
			(q) => q.règle === dottedName
		)
		if (estDirectementRépondue) {
			return true
		}

		const rule = engine.getRule(dottedName)
		const plusieursPossibilités = rule.rawNode['plusieurs possibilités']
		const estPlusieursPossibilités =
			Array.isArray(plusieursPossibilités) && plusieursPossibilités.length > 0

		if (estPlusieursPossibilités) {
			return questionsRépondues.some((q) =>
				q.règle.startsWith(dottedName + ' . ')
			)
		}

		return false
	}

import { Adresse } from '@/domaine/Adresse'
import { CodeActivite } from '@/domaine/CodeActivite'
import { Siret } from '@/domaine/Siren'

export interface Établissement {
	siret: Siret
	adresse: Adresse
	activitéPrincipale: CodeActivite
}

