// =============================================================================
// AUTH: everything about Cognito lives here.
// Sign-in uses SRP, so the password itself is never sent over the network.
// The library stores tokens in the browser and refreshes them automatically.
// =============================================================================

const {
    CognitoUserPool,
    CognitoUser,
    CognitoUserAttribute,
    AuthenticationDetails,
} = window.AmazonCognitoIdentity;

const config = window.APP_CONFIG;

const userPool = new CognitoUserPool({
    UserPoolId: config.userPoolId,
    ClientId: config.userPoolClientId,
});

function cognitoUser(email) {
    return new CognitoUser({ Username: email, Pool: userPool });
}

// The library uses old-style callbacks: function (error, result).
// This helper turns them into Promises, so we can use async/await.
function callbackToPromise(resolve, reject) {
    return (error, result) => (error ? reject(error) : resolve(result));
}

export function signUp(email, password) {
    const attributes = [new CognitoUserAttribute({ Name: "email", Value: email })];
    return new Promise((resolve, reject) => {
        userPool.signUp(email, password, attributes, null, callbackToPromise(resolve, reject));
    });
}

export function confirmSignUp(email, code) {
    return new Promise((resolve, reject) => {
        cognitoUser(email).confirmRegistration(code, true, callbackToPromise(resolve, reject));
    });
}

export function resendCode(email) {
    return new Promise((resolve, reject) => {
        cognitoUser(email).resendConfirmationCode(callbackToPromise(resolve, reject));
    });
}

export function signIn(email, password) {
    const details = new AuthenticationDetails({ Username: email, Password: password });
    return new Promise((resolve, reject) => {
        cognitoUser(email).authenticateUser(details, {
            onSuccess: resolve,
            onFailure: reject,
        });
    });
}

export function signOut() {
    const user = userPool.getCurrentUser();
    if (user) {
        user.signOut(); // removes the stored tokens from this browser
    }
}

// The current session, or null if nobody is signed in.
// If the access token has expired, getSession uses the refresh token
// to get a new one automatically. That's why users stay signed in.
function currentSession() {
    return new Promise((resolve) => {
        const user = userPool.getCurrentUser();
        if (!user) {
            resolve(null);
            return;
        }
        user.getSession((error, session) => {
            resolve(!error && session && session.isValid() ? session : null);
        });
    });
}

export async function getAccessToken() {
    const session = await currentSession();
    if (!session) {
        throw new Error("Not signed in");
    }
    return session.getAccessToken().getJwtToken();
}

export async function getSignedInEmail() {
    const session = await currentSession();
    return session ? session.getIdToken().payload.email : null;
}