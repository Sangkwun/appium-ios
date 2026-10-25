import {util} from '@appium/support';
import type {StringRecord} from '@appium/types';
import {Services} from 'appium-ios-remotexpc';
import type {WebInspectorService} from 'appium-ios-remotexpc';

import {log} from '../logger.js';
import type {RemoteCommand, RpcClientOptions} from '../types.js';
import {RpcClient} from './rpc-client.js';

const LISTENER_STOP_TIMEOUT_MS = 5000;

/**
 * Options specific to RpcClientRealDevice.
 */
export interface RpcClientRealDeviceOptions extends RpcClientOptions {
  /** The device UDID (required for the RemoteXPC connection) */
  udid: string;
}

/**
 * Interface for WebInspector message structure from the service.
 */
interface WebInspectorMessage {
  __selector: string;
  __argument: StringRecord;
}

/**
 * RPC client implementation for iOS/tvOS 18+ real devices.
 * This client uses the `com.apple.webinspector.shim.remote` service via RemoteXPC
 * tunneling, which is required for iOS 18 and later where the traditional
 * Web Inspector service is no longer available.
 *
 * Extends RpcClient to provide device-specific connection handling using
 * the appium-ios-remotexpc library.
 */
export class RpcClientRealDevice extends RpcClient {
  protected webInspectorService?: WebInspectorService;
  protected messageListenerTask?: Promise<void>;
  protected isListening: boolean = false;

  /** Narrows the options type so that `udid` is required. */
  constructor(opts: RpcClientRealDeviceOptions) {
    super(opts);
  }

  /**
   * Connects to the WebInspector service on an iOS 18+ real device.
   * Uses the RemoteXPC tunnel to establish a connection to the
   * `com.apple.webinspector.shim.remote` service.
   */
  override async connect(): Promise<void> {
    if (this.isConnected) {
      return;
    }
    log.debug(`Connecting to WebInspector service for device ${this.udid}`);

    this.webInspectorService = await Services.startWebInspectorService(this.udid);

    this.startMessageListener();
    this.isConnected = true;
    log.debug('Successfully connected to WebInspector service');
  }

  /**
   * Disconnects from the WebInspector service.
   * Closes the service connection and cleans up resources.
   */
  override async disconnect(): Promise<void> {
    const service = this.webInspectorService;
    if (!this.isConnected && !service) {
      return;
    }

    log.debug('Disconnecting from WebInspector service');
    await super.disconnect();

    // Detach first so a stale listener cannot affect a later reconnect
    const listenerTask = this.messageListenerTask;
    this.webInspectorService = undefined;
    this.messageListenerTask = undefined;
    this.isListening = false;
    this.isConnected = false;

    if (service) {
      try {
        await service.stopListeningAsync();
      } catch (err: any) {
        log.warn('Error while stopping message listener', err);
      }
      try {
        await service.close();
      } catch (err: any) {
        log.warn('Error while closing the WebInspector service', err);
      }
    }

    if (listenerTask) {
      let timer: NodeJS.Timeout | undefined;
      const timeout = new Promise<void>((resolve) => {
        timer = setTimeout(resolve, LISTENER_STOP_TIMEOUT_MS);
      });
      try {
        await Promise.race([listenerTask, timeout]);
      } finally {
        clearTimeout(timer);
      }
    }
    log.debug('Disconnected from WebInspector service');
  }

  /**
   * Sends a command message to the WebInspector service.
   * Translates the RemoteCommand format to the service format.
   *
   * @param cmd - The command to send to the device.
   */
  override async sendMessage(cmd: RemoteCommand): Promise<void> {
    if (!this.webInspectorService) {
      throw new Error('WebInspector service is not initialized. Is the client connected?');
    }

    const selector = cmd.__selector;
    const args = this.translateArguments(cmd.__argument);

    log.debug(`Sending message: ${selector}`);
    await this.webInspectorService.sendMessage(selector, args);
  }

  /**
   * Receives data from the WebInspector service and handles it.
   * This method is called by the message listener when a message is received.
   *
   * @param data - The data received from the service.
   */
  override async receive(data: any): Promise<void> {
    if (this.isConnected && data) {
      await this.messageHandler.handleMessage(data);
    }
  }

  /**
   * Starts the background message listener that receives messages from
   * the WebInspector service and forwards them to the message handler.
   */
  private startMessageListener(): void {
    if (this.isListening || !this.webInspectorService) {
      return;
    }

    this.isListening = true;
    const service = this.webInspectorService;

    this.messageListenerTask = (async () => {
      try {
        for await (const message of service.listenMessage()) {
          if (this.webInspectorService !== service) {
            break;
          }
          try {
            await this.receive(this.convertMessage(message as unknown as WebInspectorMessage));
          } catch (err: any) {
            // a single bad message must not stop the listener
            log.error(`Cannot handle Web Inspector message: ${err.message}`);
          }
        }
      } catch (err: any) {
        if (this.webInspectorService === service) {
          log.error('Error in message listener', err);
        }
      } finally {
        // the stream ended on its own: flag the client as disconnected instead of letting commands time out
        if (this.webInspectorService === service) {
          log.warn('The WebInspector message stream has ended');
          this.isListening = false;
          this.isConnected = false;
        }
      }
    })();
  }

  /**
   * Converts a message from the WebInspector service format to the format
   * expected by the message handler.
   *
   * @param message - The message from the service.
   * @returns The converted message in the expected format.
   */
  private convertMessage(message: WebInspectorMessage): StringRecord {
    const converted: StringRecord = {
      __selector: message.__selector,
    };

    // Convert buffer data to strings where necessary
    if (util.isPlainObject(message.__argument)) {
      const args = {...message.__argument};

      // Handle WIRMessageDataKey and WIRSocketDataKey which may be buffers
      for (const key of ['WIRMessageDataKey', 'WIRSocketDataKey', 'WIRDestinationKey']) {
        if (args[key] !== undefined && Buffer.isBuffer(args[key])) {
          args[key] = (args[key] as Buffer).toString('utf8');
        }
      }
      converted.__argument = args;
    }

    return converted;
  }

  /**
   * Translates command arguments from the RemoteCommand format to the
   * format expected by the WebInspector service.
   *
   * @param args - The arguments from the RemoteCommand.
   * @returns The translated arguments for the service.
   */
  private translateArguments(args: any): StringRecord {
    if (!util.isPlainObject(args)) {
      return {};
    }

    const translated: StringRecord = {...args};

    // Remove the connection identifier key as it will be added by the service
    delete translated.WIRConnectionIdentifierKey;

    return translated;
  }
}
