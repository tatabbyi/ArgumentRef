import type { AppConfig } from '../config.js';
import type {
  ClaimDetectedEvent,
  FactCheckCompletedEvent,
  FactCheckSource,
  FactCheckStatus,
} from '../protocol/messages.js';

type FetchFn = typeof fetch;

export interface FactCheckResult {
  status: FactCheckStatus;
  summary: string;
  sources: FactCheckSource[];
}

export interface FactCheckProvider {
  checkClaim(claim: ClaimDetectedEvent): Promise<FactCheckResult>;
}

export class GoogleFactCheckProvider implements FactCheckProvider {
  constructor(
    private readonly config: Pick<
      AppConfig,
      | 'googleFactCheckApiKey'
      | 'googleFactCheckLanguageCode'
      | 'googleFactCheckPageSize'
    >,
    private readonly fetchFn: FetchFn = fetch,
  ) {}

  async checkClaim(claim: ClaimDetectedEvent): Promise<FactCheckResult> {
    if (!this.config.googleFactCheckApiKey) {
      throw new Error('GOOGLE_FACT_CHECK_API_KEY is not configured.');
    }

    const url = buildFactCheckUrl(this.config, claim.text);
    const response = await this.fetchFn(url, {
      signal: AbortSignal.timeout(8000),
    });

    if (!response.ok) {
      throw new Error(
        `Google Fact Check API failed with ${response.status} ${response.statusText}`,
      );
    }

    const payload = (await response.json()) as GoogleFactCheckSearchResponse;
    const sources = extractSources(payload, this.config.googleFactCheckPageSize);

    if (sources.length === 0) {
      return {
        status: 'no_match',
        summary: 'No matching published fact check was found.',
        sources,
      };
    }

    return {
      status: 'matched_fact_check',
      summary: summarizeSources(sources),
      sources,
    };
  }
}

export function toFactCheckCompletedEvent(
  claim: ClaimDetectedEvent,
  result: FactCheckResult,
): FactCheckCompletedEvent {
  return {
    type: 'fact_check.completed',
    provider: 'google-fact-check',
    claimId: claim.claimId,
    sessionId: claim.sessionId,
    streamId: claim.streamId,
    speaker: claim.speaker,
    speakerLabel: claim.speakerLabel,
    claim: claim.text,
    status: result.status,
    summary: result.summary,
    sources: result.sources,
  };
}

function buildFactCheckUrl(
  config: Pick<
    AppConfig,
    'googleFactCheckApiKey' | 'googleFactCheckLanguageCode' | 'googleFactCheckPageSize'
  >,
  claimText: string,
): string {
  const url = new URL('https://factchecktools.googleapis.com/v1alpha1/claims:search');
  url.searchParams.set('query', claimText);
  url.searchParams.set('languageCode', config.googleFactCheckLanguageCode);
  url.searchParams.set('pageSize', String(config.googleFactCheckPageSize));
  url.searchParams.set('key', config.googleFactCheckApiKey ?? '');

  return url.toString();
}

interface GoogleFactCheckSearchResponse {
  claims?: GoogleFactCheckClaim[];
}

interface GoogleFactCheckClaim {
  text?: string;
  claimant?: string;
  claimReview?: GoogleFactCheckReview[];
}

interface GoogleFactCheckReview {
  publisher?: {
    name?: string;
    site?: string;
  };
  url?: string;
  title?: string;
  textualRating?: string;
}

function extractSources(
  payload: GoogleFactCheckSearchResponse,
  limit: number,
): FactCheckSource[] {
  const sources: FactCheckSource[] = [];

  for (const claim of payload.claims ?? []) {
    for (const review of claim.claimReview ?? []) {
      if (!review.url) {
        continue;
      }

      sources.push({
        title: review.title ?? claim.text ?? 'Fact check result',
        url: review.url,
        publisher: review.publisher?.name ?? review.publisher?.site,
        rating: review.textualRating,
        reviewedClaim: claim.text,
      });

      if (sources.length >= limit) {
        return sources;
      }
    }
  }

  return sources;
}

function summarizeSources(sources: FactCheckSource[]): string {
  const first = sources[0];
  const publisher = first.publisher ? ` from ${first.publisher}` : '';
  const rating = first.rating ? ` Rating: ${first.rating}.` : '';

  return `Found ${sources.length} published fact check result${
    sources.length === 1 ? '' : 's'
  }${publisher}.${rating}`;
}
