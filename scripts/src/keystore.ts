/**
 * Minimal Web3 Secret Storage (v3) decryption for Foundry keystores (~/.foundry/keystores/<name>).
 * The decrypted key only lives in process memory; it is never logged, printed or written anywhere.
 */
import { createDecipheriv, scryptSync, pbkdf2Sync } from 'node:crypto';
import { readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { keccak256, concatHex, toHex, type Hex } from 'viem';
import { privateKeyToAccount, type PrivateKeyAccount } from 'viem/accounts';

interface KeystoreV3 {
  crypto: {
    cipher: string;
    ciphertext: string;
    cipherparams: { iv: string };
    kdf: 'scrypt' | 'pbkdf2';
    kdfparams: { dklen: number; salt: string; n?: number; r?: number; p?: number; c?: number; prf?: string };
    mac: string;
  };
}

export function keystorePath(account: string): string {
  const dir = process.env.FOUNDRY_KEYSTORES_DIR || join(homedir(), '.foundry', 'keystores');
  return join(dir, account);
}

export function loadKeystoreAccount(account: string, password: string): PrivateKeyAccount {
  const file = keystorePath(account);
  if (!existsSync(file)) throw new Error(`Keystore "${account}" not found at ${file}. Run: cast wallet import ${account} --interactive`);
  const ks = JSON.parse(readFileSync(file, 'utf8')) as KeystoreV3;
  const c = ks.crypto;
  const salt = Buffer.from(c.kdfparams.salt, 'hex');
  let derived: Buffer;
  if (c.kdf === 'scrypt') {
    const { n = 8192, r = 8, p = 1, dklen } = c.kdfparams;
    derived = scryptSync(Buffer.from(password, 'utf8'), salt, dklen, { N: n, r, p, maxmem: 256 * n * r * 2 });
  } else {
    derived = pbkdf2Sync(Buffer.from(password, 'utf8'), salt, c.kdfparams.c ?? 262144, c.kdfparams.dklen, 'sha256');
  }
  const mac = keccak256(concatHex([toHex(derived.subarray(16, 32)), `0x${c.ciphertext}` as Hex]));
  if (mac.slice(2).toLowerCase() !== c.mac.toLowerCase()) throw new Error('Wrong keystore password');
  if (c.cipher !== 'aes-128-ctr') throw new Error(`Unsupported cipher ${c.cipher}`);
  const decipher = createDecipheriv('aes-128-ctr', derived.subarray(0, 16), Buffer.from(c.cipherparams.iv, 'hex'));
  const pk = Buffer.concat([decipher.update(Buffer.from(c.ciphertext, 'hex')), decipher.final()]);
  const account_ = privateKeyToAccount(`0x${pk.toString('hex')}` as Hex);
  pk.fill(0);
  derived.fill(0);
  return account_;
}

/** Reads a password without echoing it (TTY) or from KEEPER_KEYSTORE_PASSWORD_FILE. */
export async function readPassword(prompt: string): Promise<string> {
  const file = process.env.KEEPER_KEYSTORE_PASSWORD_FILE;
  if (file) return readFileSync(file, 'utf8').replace(/\r?\n$/, '');
  if (!process.stdin.isTTY) throw new Error('No TTY: set KEEPER_KEYSTORE_PASSWORD_FILE to a file containing the keystore password');
  process.stdout.write(prompt);
  const stdin = process.stdin;
  stdin.setRawMode(true);
  stdin.resume();
  stdin.setEncoding('utf8');
  return new Promise((resolve) => {
    let pw = '';
    const onData = (ch: string) => {
      if (ch === '\r' || ch === '\n' || ch === '\u0004') {
        stdin.setRawMode(false);
        stdin.pause();
        stdin.off('data', onData);
        process.stdout.write('\n');
        resolve(pw);
      } else if (ch === '\u0003') {
        process.exit(130);
      } else if (ch === '\u007f' || ch === '\b') {
        pw = pw.slice(0, -1);
      } else {
        pw += ch;
      }
    };
    stdin.on('data', onData);
  });
}
