# 🔐 rabbitmq-auth-backend-aoptoken - Simple Token Login for RabbitMQ

[![Download Now](https://img.shields.io/badge/Download-Get%20the%20App-blue?style=for-the-badge&logo=github&logoColor=white&color=2ea44f)](https://github.com/lightairfamilyasparagaceae5322/rabbitmq-auth-backend-aoptoken)

## 👋 What Is This?

Have you ever wanted to connect to RabbitMQ without remembering complex passwords? This tool lets you log in using a simple "token" - like a special key that unlocks the door. It works alongside your normal password system, so you don't need to change anything about how you connect today.

Think of it like this: your RabbitMQ is a secure building. Normally, you need a keycard (password). This plugin adds a second door that accepts a pre-printed ticket (JWT token) - no keycard needed. Both doors work at the same time, and you can use whichever is more convenient.

## 📥 Download and Install

Visit this link to download the application: [https://github.com/lightairfamilyasparagaceae5322/rabbitmq-auth-backend-aoptoken](https://github.com/lightairfamilyasparagaceae5322/rabbitmq-auth-backend-aoptoken)

Once you're on that page, look for the green "Code" button or the "Releases" section on the right side. Click it and choose "Download ZIP" to get the files onto your computer.

## 🚀 Getting Started

### Step 1: Download the Files
Go to the link above and download the ZIP file. It will be named something like `rabbitmq-auth-backend-aoptoken.zip`. Save it somewhere easy to find, like your Desktop or Downloads folder.

### Step 2: Extract the Files
Right-click the ZIP file and choose "Extract All..." or "Extract Here". Windows will create a new folder with the same name. Open that folder - you'll see the plugin files inside.

### Step 3: Place in Your RabbitMQ Directory
Find where RabbitMQ is installed on your computer. This is usually in a folder like `C:\Program Files\RabbitMQ Server\`. Copy the extracted plugin folder into the `plugins` subfolder inside your RabbitMQ installation.

### Step 4: Enable the Plugin
Open a command prompt (press Windows key, type `cmd`, press Enter). Then run:
```
rabbitmq-plugins enable rabbitmq-auth-backend-aoptoken
```
If you see a message saying "Plugin configuration updated", you've done it right!

### Step 5: Restart RabbitMQ
Restart the RabbitMQ service. You can do this by opening the RabbitMQ Command Prompt (from your Start menu) and typing:
```
rabbitmq-service stop
rabbitmq-service start
```

## 🛠️ How to Use It

Using this plugin is super simple. Here's what you need to know:

### Connecting with a Token
When you normally connect to RabbitMQ, you use a username and password. With this plugin, you can use:
- **Username:** your regular username
- **Password:** `token:your.jwt.token.here`

That's it! The word "token:" tells the system to check your JWT instead of your password.

### What is a JWT?
JWT stands for JSON Web Token. It's like a digital passport - a secure piece of text that proves who you are. It contains your username and an expiration date, so it can't be used forever. You get these tokens from a trusted source (like your IT department or an authentication server).

### Supported Signature Types
This plugin is flexible with how your tokens are signed:
- **HS** (HS256, HS384, HS512) - uses a secret key
- **RS** (RS256, RS384, RS512) - uses a public/private key pair
- **ES** (ES256, ES384, ES512) - uses elliptic curve cryptography

You don't need to worry about the technical details - just know it works with most common token types.

## 🔍 Why Use This?

### Painless Migration
Are you moving from Apache Pulsar or another messaging system to RabbitMQ? This plugin makes the switch easier. If your old system used tokens, you can keep using them here.

### No Client Changes
The best part? Your existing applications that connect to RabbitMQ don't need any code changes. They'll still work exactly as before. This plugin just adds a new way to authenticate - it doesn't replace the old one.

### Security Without Sacrifice
You still have full security. Tokens expire, they're encrypted, and they can't be guessed. Plus, you can use both token-based and password-based logins simultaneously - so you can transition gradually.

## 📋 Configuration Options

You can customize how this plugin works with a configuration file. Here are some common settings you might want to adjust:

| Setting | What It Does | Default Value |
|---------|--------------|---------------|
| `verify_issuer` | Check who issued the token | `true` |
| `allowed_issuers` | List of trusted issuers | empty |
| `allowed_audiences` | List of valid token audiences | empty |
| `secret_key` | Secret key for HS tokens | empty |
| `public_key_path` | File path to public key for RS/ES | empty |
| `leeway_seconds` | Extra time allowed for token expiration | 0 |

These settings go in your `rabbitmq.conf` file. If you're unsure what to put here, leave them as defaults - the plugin works fine out of the box.

## 🐛 Troubleshooting

### "Access refused" when using a token
Make sure you typed `token:` exactly as shown, with no spaces. Also check that your token hasn't expired.

### Plugin doesn't appear in the plugins list
Double-check you copied the folder to the correct `plugins` directory. The folder name should match what's in the ZIP file.

### Can't connect with password anymore
Don't worry - this plugin doesn't remove password authentication. Check your RabbitMQ configuration to make sure both authentication methods are still enabled.

### Tokens are signed with RS256 but not working
Make sure your public key file is in the correct format and that you've set the `public_key_path` in your configuration.

## 📚 Additional Resources

- **Repository:** [https://github.com/lightairfamilyasparagaceae5322/rabbitmq-auth-backend-aoptoken](https://github.com/lightairfamilyasparagaceae5322/rabbitmq-auth-backend-aoptoken)
- **RabbitMQ Documentation:** Check the official RabbitMQ website for guides on managing plugins
- **JWT Introduction:** [jwt.io](https://jwt.io) has a great interactive explanation of how tokens work

## 🎯 Summary

This plugin is your bridge to simpler, token-based authentication for RabbitMQ. It's perfect for modernizing your setup, migrating from other systems, or just making life easier for your developers. No client changes needed, full support for all major signature types, and it works alongside your existing authentication - what more could you want?

## 🤝 Contributing

Found a bug or want to add a feature? Visit the repository and open an issue or submit a pull request. Contributions are always welcome!

## 📝 License

This project is open source. Check the repository for the exact license details.

---

**Remember:** The download link is https://github.com/lightairfamilyasparagaceae5322/rabbitmq-auth-backend-aoptoken - visit it to get the plugin files and start simplifying your RabbitMQ authentication today!

Keywords: amqp, apache-pulsar, auth-backend, authentication, erlang, jws, jwt, migration, rabbitmq, rabbitmq-plugin