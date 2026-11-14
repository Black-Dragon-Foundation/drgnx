import { connect } from "./net";

/** The options a client takes. */
export interface ClientOptions {
  host: string;
  port?: number;
}

export type Handler = (msg: string) => void;

export enum State {
  Idle,
  Open,
}

/**
 * Opens a client on HOST.
 * Throws when the host is unknown.
 */
export function open(opts: ClientOptions): Client {
  return new Client(opts);
}

export const close = (c: Client): void => {
  c.stop();
};

export class Client {
  private state = State.Idle;

  constructor(private opts: ClientOptions) {}

  /** Sends one message. */
  send(msg: string): void {
    connect(this.opts.host).write(msg);
  }

  stop(): void {
    this.state = State.Idle;
  }
}

export abstract class Base {
  abstract run(): void;
}

namespace Util {
  export function pad(s: string): string {
    return " " + s;
  }
}
