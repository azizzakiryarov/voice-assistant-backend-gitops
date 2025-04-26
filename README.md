# voice-assistant-backend-gitops
GitOps repo for voice assisten - which will create todo list with help of voice and will book a calendar event 

# Installing MicroK8s on Mac

To install MicroK8s on macOS, you'll need to use Multipass since MicroK8s is primarily designed for Linux and requires virtualization on macOS. Here's how to set it up:

1. **Install Multipass**:
   ```
   brew install --cask multipass
   ```

2. **Launch MicroK8s using Multipass**:
   ```
   multipass launch --name microk8s-vm --memory 4G --disk 40G
   ```

3. **Install MicroK8s inside the VM**:
   ```
   multipass exec microk8s-vm -- sudo snap install microk8s --classic
   ```

4. **Wait for MicroK8s to start**:
   ```
   multipass exec microk8s-vm -- sudo microk8s status --wait-ready
   ```

5. **Add your user to the MicroK8s group**:
   ```
   multipass exec microk8s-vm -- sudo usermod -a -G microk8s ubuntu
   multipass exec microk8s-vm -- sudo chown -R ubuntu ~/.kube
   ```

6. **Configure kubectl on your Mac to connect to MicroK8s**:
   ```
   multipass exec microk8s-vm -- sudo microk8s config > ~/.kube/config
   ```

7. **Enable add-ons as needed**:
   ```
   multipass exec microk8s-vm -- sudo microk8s enable dns dashboard storage
   ```

You can now access your MicroK8s cluster from your Mac using kubectl commands. The shell inside the VM can be accessed using:
```
multipass shell microk8s-vm
```

If you want to stop or start the VM:
```
multipass stop microk8s-vm
multipass start microk8s-vm
```