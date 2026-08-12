"""
Trains a tiny, hardware-friendly CNN on MNIST that matches the upgraded RTL in
../rtl exactly:

    Conv2d(1  -> 8,  kernel=3, stride=1, padding=0, bias=False)   # 28x28 -> 26x26x8
    ReLU
    MaxPool2d(2, 2)                                              # -> 13x13x8
    Conv2d(8  -> 16, kernel=3, stride=1, padding=0, bias=False)  # -> 11x11x16
    ReLU
    MaxPool2d(2, 2)                                              # -> 5x5x16 = 400
    Flatten
    Linear(400 -> 10, bias=False)

Trains for 12 epochs with Adam(lr=0.001) and StepLR(step_size=4, gamma=0.5).

Run:  python train_model.py
Output: fpga_cnn_weights.pth
"""
import torch
import torch.nn as nn
import torch.optim as optim
from torchvision import datasets, transforms
from torch.utils.data import DataLoader


class FPGACNN(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1,  8,  kernel_size=3, bias=False)   # 28x28 -> 26x26x8
        self.pool1 = nn.MaxPool2d(2, 2)                              # -> 13x13x8
        self.conv2 = nn.Conv2d(8,  16, kernel_size=3, bias=False)   # -> 11x11x16
        self.pool2 = nn.MaxPool2d(2, 2)                              # -> 5x5x16 = 400
        self.fc    = nn.Linear(16 * 5 * 5, 10, bias=False)          # 400 -> 10
        self.relu  = nn.ReLU()

    def forward(self, x):
        x = self.relu(self.conv1(x))
        x = self.pool1(x)
        x = self.relu(self.conv2(x))
        x = self.pool2(x)
        x = x.view(x.size(0), -1)  # channel-major flatten, matches RTL addressing
        x = self.fc(x)
        return x


def main():
    transform = transforms.Compose([transforms.ToTensor()])
    train_dataset = datasets.MNIST(root="./data", train=True,  download=True, transform=transform)
    test_dataset  = datasets.MNIST(root="./data", train=False, download=True, transform=transform)
    train_loader  = DataLoader(train_dataset, batch_size=64, shuffle=True)
    test_loader   = DataLoader(test_dataset,  batch_size=256, shuffle=False)

    model     = FPGACNN()
    criterion = nn.CrossEntropyLoss()
    optimizer = optim.Adam(model.parameters(), lr=0.001)
    scheduler = optim.lr_scheduler.StepLR(optimizer, step_size=4, gamma=0.5)

    epochs = 12
    for epoch in range(epochs):
        model.train()
        running_loss, correct, total = 0.0, 0, 0
        for images, labels in train_loader:
            optimizer.zero_grad()
            outputs = model(images)
            loss = criterion(outputs, labels)
            loss.backward()
            optimizer.step()
            running_loss += loss.item()
            _, predicted = torch.max(outputs.data, 1)
            total   += labels.size(0)
            correct += (predicted == labels).sum().item()
        scheduler.step()
        print(f"Epoch [{epoch+1}/{epochs}] loss={running_loss/len(train_loader):.4f} "
              f"train_acc={100*correct/total:.2f}%  lr={scheduler.get_last_lr()[0]:.5f}")

    # Test accuracy
    model.eval()
    correct, total = 0, 0
    with torch.no_grad():
        for images, labels in test_loader:
            outputs = model(images)
            _, predicted = torch.max(outputs.data, 1)
            total   += labels.size(0)
            correct += (predicted == labels).sum().item()
    print(f"Test accuracy: {100*correct/total:.2f}%")

    torch.save(model.state_dict(), "fpga_cnn_weights.pth")
    print("Saved fpga_cnn_weights.pth")


if __name__ == "__main__":
    main()
