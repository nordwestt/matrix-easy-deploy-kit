# Baibot — AI Bot for Matrix

[Baibot](https://github.com/etkecc/baibot) is an AI-powered bot for Matrix that can be integrated into your rooms to provide AI assistance.

## Features

- **Multiple AI Providers**: OpenAI, Ollama, LocalAI, Groq, Anthropic, OpenRouter
- **Flexible Authentication**: Supports both password and access token (OIDC/MAS) authentication
- **Encryption**: Supports E2EE with encryption key backup
- **Admin Control**: Configure which users can administer the bot
- **Easy Setup**: Interactive wizard walks you through configuration

## Supported AI Providers

| Provider | Description |
|----------|-------------|
| OpenAI | GPT-4o, GPT-4-turbo, and more |
| Ollama | Self-hosted models (Llama, Mistral, etc.) |
| LocalAI | Self-hosted OpenAI-compatible API |
| Groq | Fast inference with free tier |
| Anthropic | Claude 3.5 Sonnet and more |
| OpenRouter | Access to multiple models |

## Setup

```bash
bash matrix-wizard.sh --module ai-bot
```

The wizard will ask for:
1. **AI Provider**: Choose your preferred AI provider
2. **API Key/Endpoint**: Credentials for your chosen provider
3. **Authentication**: Password or access token method
4. **Admin Users**: Who can administer the bot
5. **Domain** (optional): Public domain for bot access

## Usage

1. Invite `@baibot:your-server.com` to a room
2. Send `!bai help` to see available commands
3. Start chatting with the AI!

## Commands

- `!bai help` — Show help message
- `!bai models` — List available models
- `!bai model <name>` — Switch to a different model
- `!bai reset` — Reset conversation history

## Logs

```bash
docker logs -f matrix-baibot
```

## Restart

```bash
docker restart matrix-baibot
```

## Stop

```bash
cd modules/ai-bot && docker compose down
```

## More Information

- [Baibot GitHub](https://github.com/etkecc/baibot)
- [Baibot Configuration](https://github.com/etkecc/baibot/blob/main/docs/configuration/README.md)
