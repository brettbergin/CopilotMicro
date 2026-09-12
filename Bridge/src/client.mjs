import net from "node:net";

import {
  LengthPrefixedFrameDecoder,
  SequenceTracker,
  encodeLengthPrefixedFrame,
  validateFrame,
  validateFrameDirection,
  validateRegistration,
  validateRegistrationResult,
  validateSocketPath,
} from "./protocol.mjs";

const MAXIMUM_QUEUED_FRAMES = 64;

class PersistentFrameReader {
  #socket;
  #decoder = new LengthPrefixedFrameDecoder();
  #frames = [];
  #waiters = [];
  #failure = null;

  constructor(socket) {
    this.#socket = socket;
    socket.on("data", this.#onData);
    socket.on("error", this.#onError);
    socket.on("close", this.#onClose);
  }

  read(timeoutMilliseconds) {
    if (this.#frames.length > 0) return Promise.resolve(this.#frames.shift());
    if (this.#failure) return Promise.reject(this.#failure);
    return new Promise((resolve, reject) => {
      const waiter = { resolve, reject, timer: null };
      if (timeoutMilliseconds !== null) {
        waiter.timer = setTimeout(() => {
          const index = this.#waiters.indexOf(waiter);
          if (index >= 0) this.#waiters.splice(index, 1);
          const error = new Error("timedOut");
          this.destroy(error);
          reject(error);
        }, timeoutMilliseconds);
      }
      this.#waiters.push(waiter);
    });
  }

  close() {
    this.#fail(new Error("disconnected"));
    if (!this.#socket.destroyed) this.#socket.destroy();
  }

  destroy(error) {
    this.#fail(error);
    if (!this.#socket.destroyed) this.#socket.destroy();
  }

  #onData = (chunk) => {
    let frames;
    try {
      frames = this.#decoder.append(chunk);
    } catch (error) {
      this.destroy(error);
      return;
    }
    for (const frame of frames) {
      if (this.#waiters.length > 0) {
        const waiter = this.#waiters.shift();
        if (waiter.timer) clearTimeout(waiter.timer);
        waiter.resolve(frame);
      } else {
        this.#frames.push(frame);
        if (this.#frames.length > MAXIMUM_QUEUED_FRAMES) {
          this.destroy(new Error("frameQueueFull"));
          return;
        }
      }
    }
  };

  #onError = (error) => {
    this.destroy(error);
  };

  #onClose = () => {
    this.#fail(new Error("disconnected"));
  };

  #fail(error) {
    if (this.#failure) return;
    this.#failure = error;
    this.#frames = [];
    for (const waiter of this.#waiters.splice(0)) {
      if (waiter.timer) clearTimeout(waiter.timer);
      waiter.reject(error);
    }
    this.#socket.off("data", this.#onData);
    this.#socket.off("error", this.#onError);
    this.#socket.off("close", this.#onClose);
  }
}

function remainingMilliseconds(deadline) {
  const remaining = deadline - Date.now();
  if (remaining <= 0) throw new Error("timedOut");
  return remaining;
}

export async function connectAuthenticated({
  socketPath,
  registration,
  timeoutMilliseconds = 2_000,
}) {
  const pathResult = validateSocketPath(socketPath);
  if (pathResult !== "valid") throw new Error(pathResult);
  if (!Number.isSafeInteger(timeoutMilliseconds) || timeoutMilliseconds <= 0) {
    throw new Error("timedOut");
  }
  const registrationData = Buffer.from(JSON.stringify(registration));
  const validated = validateRegistration(registrationData);
  if (validated.error) throw new Error(validated.error);

  const deadline = Date.now() + timeoutMilliseconds;
  const socket = net.createConnection({ path: socketPath });
  try {
    await new Promise((resolve, reject) => {
      const onError = (error) => {
        clearTimeout(timer);
        reject(error);
      };
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new Error("timedOut"));
      }, remainingMilliseconds(deadline));
      socket.once("connect", () => {
        clearTimeout(timer);
        socket.off("error", onError);
        resolve();
      });
      socket.once("error", onError);
    });

    const reader = new PersistentFrameReader(socket);
    socket.write(encodeLengthPrefixedFrame(registrationData));
    const responseData = await reader.read(remainingMilliseconds(deadline));
    const response = validateRegistrationResult(responseData);
    if (response.error) {
      reader.destroy(new Error(response.error));
      throw new Error(response.error);
    }
    if (response.value.outcome !== "accepted") {
      reader.destroy(new Error(response.value.code));
      throw new Error(response.value.code);
    }

    let nextOutgoingSequence = 1;
    const incomingSequence = new SequenceTracker(registration.generation);
    return {
      socket,
      connectionId: response.value.connectionId,
      sendPayload(payload) {
        const frame = {
          protocolVersion: 1,
          messageType: "frame",
          role: "cliBridge",
          generation: registration.generation,
          sequence: nextOutgoingSequence,
          payload,
        };
        const validatedFrame = validateFrame(Buffer.from(JSON.stringify(frame)));
        if (validatedFrame.error) throw new Error(validatedFrame.error);
        if (validateFrameDirection(validatedFrame.value, "nativeApp") !== "allowed") {
          throw new Error("wrongRole");
        }
        socket.write(encodeLengthPrefixedFrame(Buffer.from(JSON.stringify(frame))));
        nextOutgoingSequence += 1;
      },
      async receive(receiveTimeoutMilliseconds = null) {
        if (
          receiveTimeoutMilliseconds !== null
          && (!Number.isSafeInteger(receiveTimeoutMilliseconds)
            || receiveTimeoutMilliseconds <= 0)
        ) {
          throw new Error("timedOut");
        }
        const data = await reader.read(receiveTimeoutMilliseconds);
        const validatedFrame = validateFrame(data);
        if (validatedFrame.error) {
          reader.destroy(new Error(validatedFrame.error));
          throw new Error(validatedFrame.error);
        }
        if (validateFrameDirection(validatedFrame.value, "cliBridge") !== "allowed") {
          reader.destroy(new Error("wrongRole"));
          throw new Error("wrongRole");
        }
        const sequence = incomingSequence.accept(validatedFrame.value);
        if (sequence !== "accepted") {
          reader.destroy(new Error(sequence));
          throw new Error(sequence);
        }
        return validatedFrame.value;
      },
      close() {
        reader.close();
      },
    };
  } catch (error) {
    if (!socket.destroyed) socket.destroy();
    throw error;
  }
}
