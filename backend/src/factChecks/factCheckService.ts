import type { AppConfig } from '../config.js';
import type { ClaimDetectedEvent, ServerEvent } from '../protocol/messages.js';
import {
  GoogleFactCheckProvider,
  toFactCheckCompletedEvent,
  type FactCheckProvider,
} from './googleFactCheckProvider.js';

export type EmitFactCheckEvent = (event: ServerEvent) => void;

export class FactCheckService {
  private checkedClaims = 0;

  constructor(
    private readonly config: Pick<
      AppConfig,
      | 'factCheckEnabled'
      | 'googleFactCheckApiKey'
      | 'factCheckMaxClaimsPerSession'
    >,
    private readonly provider: FactCheckProvider,
  ) {}

  checkClaim(claim: ClaimDetectedEvent, emit: EmitFactCheckEvent): void {
    if (!this.config.factCheckEnabled) {
      emit({
        type: 'fact_check.skipped',
        claimId: claim.claimId,
        sessionId: claim.sessionId,
        streamId: claim.streamId,
        reason: 'disabled',
      });
      return;
    }

    if (!this.config.googleFactCheckApiKey) {
      emit({
        type: 'fact_check.skipped',
        claimId: claim.claimId,
        sessionId: claim.sessionId,
        streamId: claim.streamId,
        reason: 'missing_api_key',
      });
      return;
    }

    if (this.checkedClaims >= this.config.factCheckMaxClaimsPerSession) {
      emit({
        type: 'fact_check.skipped',
        claimId: claim.claimId,
        sessionId: claim.sessionId,
        streamId: claim.streamId,
        reason: 'session_limit_reached',
      });
      return;
    }

    this.checkedClaims += 1;

    emit({
      type: 'fact_check.started',
      provider: 'google-fact-check',
      claimId: claim.claimId,
      sessionId: claim.sessionId,
      streamId: claim.streamId,
      speaker: claim.speaker,
      speakerLabel: claim.speakerLabel,
      claim: claim.text,
    });

    void this.provider
      .checkClaim(claim)
      .then((result) => {
        emit(toFactCheckCompletedEvent(claim, result));
      })
      .catch((error: unknown) => {
        emit({
          type: 'fact_check.failed',
          provider: 'google-fact-check',
          claimId: claim.claimId,
          sessionId: claim.sessionId,
          streamId: claim.streamId,
          message: error instanceof Error ? error.message : 'Fact check failed.',
        });
      });
  }
}

export function createFactCheckService(config: AppConfig): FactCheckService {
  return new FactCheckService(config, new GoogleFactCheckProvider(config));
}
