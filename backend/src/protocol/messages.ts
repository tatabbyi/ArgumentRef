import { z } from 'zod';

export const audioFormatSchema = z.object({
  encoding: z
    .enum(['pcm16', 'webm-opus', 'aac', 'unknown'])
    .default('unknown'),
  sampleRateHz: z.number().int().positive().optional(),
  channels: z.number().int().positive().max(8).optional(),
});

export type AudioFormat = z.infer<typeof audioFormatSchema>;

export const clientControlMessageSchema = z.discriminatedUnion('type', [
  z.object({
    type: z.literal('session.start'),
    sessionId: z.string().min(1).max(120).optional(),
    participantId: z.string().min(1).max(120).optional(),
    audio: audioFormatSchema.optional(),
  }),
  z.object({
    type: z.literal('audio.commit'),
  }),
  z.object({
    type: z.literal('session.stop'),
  }),
]);

export type ClientControlMessage = z.infer<typeof clientControlMessageSchema>;

export type ServerEvent =
  | {
      type: 'session.started';
      sessionId: string;
      streamId: string;
      participantId: string;
      audio: AudioFormat;
      acceptedBinaryAudio: true;
    }
  | {
      type: 'audio.ack';
      sessionId: string;
      streamId: string;
      bytesReceived: number;
      chunksReceived: number;
    }
  | {
      type: 'audio.committed';
      sessionId: string;
      streamId: string;
      bytesReceived: number;
      chunksReceived: number;
    }
  | {
      type: 'session.ended';
      sessionId: string;
      streamId: string;
      participantId: string;
      bytesReceived: number;
      chunksReceived: number;
      storagePath: string;
    }
  | {
      type: 'error';
      code: string;
      message: string;
    };

export function parseClientControlMessage(data: string): ClientControlMessage {
  return clientControlMessageSchema.parse(JSON.parse(data));
}

export function serializeServerEvent(event: ServerEvent): string {
  return JSON.stringify(event);
}
